use argon2::{Algorithm, Argon2, Params, Version};
use chacha20poly1305::{
    aead::{Aead, KeyInit, Payload},
    ChaCha20Poly1305, Nonce as ChaNonce,
    XChaCha20Poly1305, XNonce,
};
use rand_core::{OsRng, RngCore};
use zeroize::Zeroize;

// ── 定数 ─────────────────────────────────────────────────────────────────────

const ARGON2_M_COST: u32 = 65536; // 64 MiB
const ARGON2_T_COST: u32 = 3;
const ARGON2_P_COST: u32 = 1;

pub(crate) const KEY_LEN:        usize = 32;
pub(crate) const SALT_LEN:       usize = 16;
pub(crate) const MAX_SECRET_LEN: usize = 64 * 1024; // 64 KiB

const BLOB_V1:     u8    = 0x01; // ChaCha20-Poly1305 (12B nonce) — 読み取り専用
const BLOB_V2:     u8    = 0x02; // XChaCha20-Poly1305 (24B nonce) — 書き込み用
const FLAG_PORTABLE: u8  = 0x01;
const NONCE_V1_LEN: usize = 12;
const NONCE_V2_LEN: usize = 24;
const TAG_LEN:      usize = 16;

// ── エラー型 ──────────────────────────────────────────────────────────────────

#[derive(thiserror::Error, Debug)]
pub enum CryptoError {
    /// 復号失敗: 理由を一切表示しない（仕様）
    #[error("")]
    DecryptFailed,
    #[error("kdf error")]
    Kdf,
    #[error("encrypt error")]
    Encrypt,
    #[error("plaintext too large")]
    PlaintextTooLarge,
}

// ── KDF ───────────────────────────────────────────────────────────────────────

/// Argon2id で 32 バイト鍵を導出する（パラメータ可変）。
fn derive_key_with_params(
    m_cost: u32,
    t_cost: u32,
    p_cost: u32,
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    salt: &[u8; SALT_LEN],
) -> Result<[u8; KEY_LEN], CryptoError> {
    let params = Params::new(m_cost, t_cost, p_cost, Some(KEY_LEN))
        .map_err(|_| CryptoError::Kdf)?;
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    // Locked:   passphrase || 0x00 || machine_id
    // Portable: passphrase のみ
    let mut kdf_input: Vec<u8> =
        Vec::with_capacity(passphrase.len() + machine_id.map_or(0, |m| m.len() + 1));
    kdf_input.extend_from_slice(passphrase);
    if let Some(mid) = machine_id {
        kdf_input.push(0x00); // null セパレータ（長さ拡張攻撃防止）
        kdf_input.extend_from_slice(mid);
    }

    let mut key = [0u8; KEY_LEN];
    argon2
        .hash_password_into(&kdf_input, salt, &mut key)
        .map_err(|_| CryptoError::Kdf)?;

    kdf_input.zeroize();
    Ok(key)
}

/// 本番 Argon2id パラメータ（m=64MiB, t=3, p=1）で鍵を導出する。
pub(crate) fn derive_key(
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    salt: &[u8; SALT_LEN],
) -> Result<[u8; KEY_LEN], CryptoError> {
    derive_key_with_params(
        ARGON2_M_COST, ARGON2_T_COST, ARGON2_P_COST,
        passphrase, machine_id, salt,
    )
}

// ── seal ─────────────────────────────────────────────────────────────────────

fn seal_with_kdf_params(
    m: u32, t: u32, p: u32,
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    plaintext: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    if plaintext.len() > MAX_SECRET_LEN {
        return Err(CryptoError::PlaintextTooLarge);
    }

    let mut salt = [0u8; SALT_LEN];
    OsRng.fill_bytes(&mut salt);
    let mut nonce_bytes = [0u8; NONCE_V2_LEN];
    OsRng.fill_bytes(&mut nonce_bytes);

    let mut key = derive_key_with_params(m, t, p, passphrase, machine_id, &salt)?;

    let version = BLOB_V2;
    let flags   = if machine_id.is_none() { FLAG_PORTABLE } else { 0u8 };

    let cipher = XChaCha20Poly1305::new_from_slice(&key)
        .map_err(|_| CryptoError::Encrypt)?;
    key.zeroize();

    let nonce = XNonce::from_slice(&nonce_bytes);
    let ct_with_tag = cipher
        .encrypt(nonce, Payload { msg: plaintext, aad: &[version] })
        .map_err(|_| CryptoError::Encrypt)?;
    // ct_with_tag = ciphertext(plaintext.len()) + tag(16)

    let ct_len = plaintext.len() as u32;
    let mut blob = Vec::with_capacity(
        1 + 1 + SALT_LEN + NONCE_V2_LEN + 4 + ct_with_tag.len(),
    );
    blob.push(version);
    blob.push(flags);
    blob.extend_from_slice(&salt);
    blob.extend_from_slice(&nonce_bytes);
    blob.extend_from_slice(&ct_len.to_be_bytes());
    blob.extend_from_slice(&ct_with_tag);

    Ok(blob)
}

/// シークレットを暗号化して blob を返す。
///
/// - `machine_id = Some(id)` → Locked mode（machine_id にバインド）
/// - `machine_id = None`     → Portable mode
pub fn seal(
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    plaintext: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    seal_with_kdf_params(
        ARGON2_M_COST, ARGON2_T_COST, ARGON2_P_COST,
        passphrase, machine_id, plaintext,
    )
}

// ── unseal ────────────────────────────────────────────────────────────────────

fn unseal_with_kdf_params(
    m: u32, t: u32, p: u32,
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    blob: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    // 最小長チェック: version(1) + flags(1) + salt(16) + nonce_min(12) + ct_len(4) + tag(16)
    if blob.len() < 1 + 1 + SALT_LEN + NONCE_V1_LEN + 4 + TAG_LEN {
        return Err(CryptoError::DecryptFailed);
    }

    let version = blob[0];
    let flags   = blob[1];

    // 未知のフラグビット（bit1 以上）を拒否
    if flags & !FLAG_PORTABLE != 0 {
        return Err(CryptoError::DecryptFailed);
    }

    let is_portable          = flags & FLAG_PORTABLE != 0;
    let effective_machine_id = if is_portable { None } else { machine_id };

    let salt: &[u8; SALT_LEN] = blob[2..2 + SALT_LEN]
        .try_into()
        .map_err(|_| CryptoError::DecryptFailed)?;

    let nonce_len = match version {
        BLOB_V1 => NONCE_V1_LEN,
        BLOB_V2 => NONCE_V2_LEN,
        _       => return Err(CryptoError::DecryptFailed),
    };

    let nonce_start  = 2 + SALT_LEN;
    let nonce_end    = nonce_start + nonce_len;
    let ct_len_start = nonce_end;
    let ct_len_end   = ct_len_start + 4;

    if blob.len() < ct_len_end {
        return Err(CryptoError::DecryptFailed);
    }

    let ct_len = u32::from_be_bytes(
        blob[ct_len_start..ct_len_end]
            .try_into()
            .map_err(|_| CryptoError::DecryptFailed)?,
    ) as usize;

    // ct_len を MAX_SECRET_LEN で検証してからアロケート（OOM 防止）
    if ct_len > MAX_SECRET_LEN {
        return Err(CryptoError::DecryptFailed);
    }

    let ct_start  = ct_len_end;
    let tag_end   = ct_start + ct_len + TAG_LEN;

    if blob.len() < tag_end {
        return Err(CryptoError::DecryptFailed);
    }

    let ct_with_tag = &blob[ct_start..tag_end]; // ciphertext + tag

    let mut key = derive_key_with_params(m, t, p, passphrase, effective_machine_id, salt)?;

    let plaintext = match version {
        BLOB_V1 => {
            let cipher = ChaCha20Poly1305::new_from_slice(&key)
                .map_err(|_| CryptoError::DecryptFailed)?;
            key.zeroize();
            let nonce = ChaNonce::from_slice(&blob[nonce_start..nonce_end]);
            cipher
                .decrypt(nonce, Payload { msg: ct_with_tag, aad: &[version] })
                .map_err(|_| CryptoError::DecryptFailed)?
        }
        BLOB_V2 => {
            let cipher = XChaCha20Poly1305::new_from_slice(&key)
                .map_err(|_| CryptoError::DecryptFailed)?;
            key.zeroize();
            let nonce = XNonce::from_slice(&blob[nonce_start..nonce_end]);
            cipher
                .decrypt(nonce, Payload { msg: ct_with_tag, aad: &[version] })
                .map_err(|_| CryptoError::DecryptFailed)?
        }
        _ => return Err(CryptoError::DecryptFailed),
    };

    Ok(plaintext)
}

/// blob を復号して平文を返す。blob の flags から Locked/Portable を自動判定する。
pub fn unseal(
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    blob: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    unseal_with_kdf_params(
        ARGON2_M_COST, ARGON2_T_COST, ARGON2_P_COST,
        passphrase, machine_id, blob,
    )
}

// ── re-seal ───────────────────────────────────────────────────────────────────

fn reseal_with_kdf_params(
    m: u32, t: u32, p: u32,
    old_passphrase: &[u8],
    new_passphrase: &[u8],
    machine_id: Option<&[u8]>,
    old_blob: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    // 元の blob の mode（Locked/Portable）を保持する
    let is_portable          = old_blob.len() > 1 && (old_blob[1] & FLAG_PORTABLE != 0);
    let effective_machine_id = if is_portable { None } else { machine_id };

    let mut plaintext =
        unseal_with_kdf_params(m, t, p, old_passphrase, machine_id, old_blob)?;

    let new_blob =
        seal_with_kdf_params(m, t, p, new_passphrase, effective_machine_id, &plaintext)?;

    plaintext.zeroize();
    Ok(new_blob)
}

/// 既存 blob を旧パスフレーズで復号し、新パスフレーズで v2 として再暗号化する。
/// Locked/Portable モードは元の blob から引き継ぐ。
#[allow(dead_code)]
pub fn reseal(
    old_passphrase: &[u8],
    new_passphrase: &[u8],
    machine_id: Option<&[u8]>,
    old_blob: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    reseal_with_kdf_params(
        ARGON2_M_COST, ARGON2_T_COST, ARGON2_P_COST,
        old_passphrase, new_passphrase, machine_id, old_blob,
    )
}

// ── テスト ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn kdf(passphrase: &[u8], machine_id: Option<&[u8]>, salt: &[u8; 16]) -> [u8; KEY_LEN] {
        derive_key_with_params(8, 1, 1, passphrase, machine_id, salt).unwrap()
    }

    fn do_seal(passphrase: &[u8], machine_id: Option<&[u8]>, plaintext: &[u8]) -> Vec<u8> {
        seal_with_kdf_params(8, 1, 1, passphrase, machine_id, plaintext).unwrap()
    }

    fn do_unseal(
        passphrase: &[u8],
        machine_id: Option<&[u8]>,
        blob: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        unseal_with_kdf_params(8, 1, 1, passphrase, machine_id, blob)
    }

    fn do_reseal(
        old_pass: &[u8],
        new_pass: &[u8],
        machine_id: Option<&[u8]>,
        blob: &[u8],
    ) -> Result<Vec<u8>, CryptoError> {
        reseal_with_kdf_params(8, 1, 1, old_pass, new_pass, machine_id, blob)
    }

    // ── KDF パラメータ ─────────────────────────────────────────────────────────

    // [ ] 導出鍵は正確に 32 バイト
    #[test]
    fn kdf_output_is_32_bytes() {
        assert_eq!(kdf(b"pass", Some(b"mid"), &[0u8; 16]).len(), 32);
    }

    // [ ] 決定論的
    #[test]
    fn kdf_is_deterministic() {
        let salt = [0x42u8; 16];
        assert_eq!(
            kdf(b"pass", Some(b"mid"), &salt),
            kdf(b"pass", Some(b"mid"), &salt),
        );
    }

    // [ ] Locked と Portable は異なる鍵
    #[test]
    fn locked_and_portable_produce_different_keys() {
        let salt = [0u8; 16];
        assert_ne!(kdf(b"pass", Some(b"mid"), &salt), kdf(b"pass", None, &salt));
    }

    // [ ] null セパレータで長さ拡張攻撃を防ぐ
    #[test]
    fn null_separator_prevents_length_extension() {
        let salt = [0u8; 16];
        assert_ne!(
            kdf(b"passA", Some(b"B"),  &salt),
            kdf(b"pass",  Some(b"AB"), &salt),
        );
    }

    // [ ] 異なる machine_id は異なる鍵
    #[test]
    fn different_machine_ids_produce_different_keys() {
        let salt = [0u8; 16];
        assert_ne!(
            kdf(b"pass", Some(b"machine-A"), &salt),
            kdf(b"pass", Some(b"machine-B"), &salt),
        );
    }

    // [ ] 異なるソルトは異なる鍵
    #[test]
    fn different_salts_produce_different_keys() {
        assert_ne!(
            kdf(b"pass", Some(b"mid"), &[0u8; 16]),
            kdf(b"pass", Some(b"mid"), &[1u8; 16]),
        );
    }

    // ── 暗号化の正確性 ─────────────────────────────────────────────────────────

    // [ ] 新規 seal は blob version 0x02（XChaCha20）を使用する
    #[test]
    fn seal_uses_blob_version_v2() {
        let blob = do_seal(b"pass", Some(b"mid"), b"secret");
        assert_eq!(blob[0], BLOB_V2);
    }

    // [ ] nonce は 24 バイト（XChaCha20 の仕様）
    #[test]
    fn seal_nonce_is_24_bytes() {
        let blob = do_seal(b"pass", Some(b"mid"), b"secret");
        let nonce = &blob[2 + SALT_LEN..2 + SALT_LEN + NONCE_V2_LEN];
        assert_eq!(nonce.len(), 24);
    }

    // [ ] seal ごとに異なる nonce（同じ平文でも異なる blob）
    #[test]
    fn each_seal_produces_unique_blob() {
        assert_ne!(
            do_seal(b"pass", Some(b"mid"), b"secret"),
            do_seal(b"pass", Some(b"mid"), b"secret"),
        );
    }

    // [ ] Locked mode: seal → unseal ラウンドトリップ
    #[test]
    fn roundtrip_locked() {
        let pt = b"my-secret-value";
        let blob = do_seal(b"passphrase", Some(b"machine-id"), pt);
        assert_eq!(do_unseal(b"passphrase", Some(b"machine-id"), &blob).unwrap(), pt);
    }

    // [ ] Portable mode: seal → unseal ラウンドトリップ
    #[test]
    fn roundtrip_portable() {
        let pt = b"portable-secret";
        let blob = do_seal(b"passphrase", None, pt);
        assert_eq!(do_unseal(b"passphrase", None, &blob).unwrap(), pt);
    }

    // [ ] Portable blob は machine_id が違っても復号できる
    #[test]
    fn portable_unseals_with_any_machine_id() {
        let blob = do_seal(b"pass", None, b"secret");
        assert_eq!(
            do_unseal(b"pass", Some(b"any-machine"), &blob).unwrap(),
            b"secret",
        );
    }

    // [ ] パスフレーズが違うと DecryptFailed
    #[test]
    fn wrong_passphrase_fails() {
        let blob = do_seal(b"correct", Some(b"mid"), b"secret");
        assert!(matches!(
            do_unseal(b"wrong", Some(b"mid"), &blob),
            Err(CryptoError::DecryptFailed),
        ));
    }

    // [ ] Locked mode: machine_id が違うと DecryptFailed
    #[test]
    fn wrong_machine_id_fails() {
        let blob = do_seal(b"pass", Some(b"machine-A"), b"secret");
        assert!(matches!(
            do_unseal(b"pass", Some(b"machine-B"), &blob),
            Err(CryptoError::DecryptFailed),
        ));
    }

    // [ ] AAD（version バイト）を改ざんすると認証失敗
    #[test]
    fn tampered_version_byte_fails() {
        let mut blob = do_seal(b"pass", Some(b"mid"), b"secret");
        blob[0] ^= 0xff;
        assert!(matches!(
            do_unseal(b"pass", Some(b"mid"), &blob),
            Err(CryptoError::DecryptFailed),
        ));
    }

    // [ ] 暗号文を 1 バイト改ざんすると Poly1305 タグ検証で失敗
    #[test]
    fn tampered_ciphertext_fails() {
        let mut blob = do_seal(b"pass", Some(b"mid"), b"secret");
        let ct_start = 1 + 1 + SALT_LEN + NONCE_V2_LEN + 4;
        blob[ct_start] ^= 0xff;
        assert!(matches!(
            do_unseal(b"pass", Some(b"mid"), &blob),
            Err(CryptoError::DecryptFailed),
        ));
    }

    // [ ] ct_len > MAX_SECRET_LEN → DecryptFailed（OOM 防止）
    #[test]
    fn oversized_ct_len_field_fails() {
        let mut blob = do_seal(b"pass", Some(b"mid"), b"secret");
        // ct_len フィールドを MAX_SECRET_LEN + 1 に書き換える
        let ct_len_start = 1 + 1 + SALT_LEN + NONCE_V2_LEN;
        let bad_len = (MAX_SECRET_LEN as u32 + 1).to_be_bytes();
        blob[ct_len_start..ct_len_start + 4].copy_from_slice(&bad_len);
        assert!(matches!(
            do_unseal(b"pass", Some(b"mid"), &blob),
            Err(CryptoError::DecryptFailed),
        ));
    }

    // [ ] plaintext > MAX_SECRET_LEN → PlaintextTooLarge
    #[test]
    fn plaintext_too_large_fails() {
        let big = vec![0u8; MAX_SECRET_LEN + 1];
        assert!(matches!(
            seal_with_kdf_params(8, 1, 1, b"pass", Some(b"mid"), &big),
            Err(CryptoError::PlaintextTooLarge),
        ));
    }

    // [ ] blob version 先読み: v1 blob（ChaCha20, 12B nonce）を unseal できる
    #[test]
    fn v1_backward_compat_roundtrip() {
        let passphrase = b"pass";
        let machine_id = Some(b"mid".as_slice());
        let plaintext  = b"old-secret";

        // v1 blob を手動で組み立てる
        let mut salt = [0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        let mut nonce_bytes = [0u8; NONCE_V1_LEN];
        OsRng.fill_bytes(&mut nonce_bytes);

        let key    = derive_key_with_params(8, 1, 1, passphrase, machine_id, &salt).unwrap();
        let cipher = ChaCha20Poly1305::new_from_slice(&key).unwrap();
        let nonce  = ChaNonce::from_slice(&nonce_bytes);
        let ct_with_tag = cipher
            .encrypt(nonce, Payload { msg: plaintext, aad: &[BLOB_V1] })
            .unwrap();

        let mut blob = Vec::new();
        blob.push(BLOB_V1);
        blob.push(0u8); // locked
        blob.extend_from_slice(&salt);
        blob.extend_from_slice(&nonce_bytes);
        blob.extend_from_slice(&(plaintext.len() as u32).to_be_bytes());
        blob.extend_from_slice(&ct_with_tag);

        assert_eq!(do_unseal(passphrase, machine_id, &blob).unwrap(), plaintext);
    }

    // [ ] re-seal: v1 blob を新パスフレーズで v2 に再暗号化する
    #[test]
    fn reseal_upgrades_v1_to_v2_and_changes_passphrase() {
        let machine_id = Some(b"mid".as_slice());
        let plaintext  = b"reseal-secret";

        // v1 blob を手動で組み立てる
        let mut salt = [0u8; SALT_LEN];
        OsRng.fill_bytes(&mut salt);
        let mut nonce_bytes = [0u8; NONCE_V1_LEN];
        OsRng.fill_bytes(&mut nonce_bytes);

        let key    = derive_key_with_params(8, 1, 1, b"old-pass", machine_id, &salt).unwrap();
        let cipher = ChaCha20Poly1305::new_from_slice(&key).unwrap();
        let nonce  = ChaNonce::from_slice(&nonce_bytes);
        let ct_with_tag = cipher
            .encrypt(nonce, Payload { msg: plaintext, aad: &[BLOB_V1] })
            .unwrap();
        let mut v1_blob = Vec::new();
        v1_blob.push(BLOB_V1);
        v1_blob.push(0u8);
        v1_blob.extend_from_slice(&salt);
        v1_blob.extend_from_slice(&nonce_bytes);
        v1_blob.extend_from_slice(&(plaintext.len() as u32).to_be_bytes());
        v1_blob.extend_from_slice(&ct_with_tag);

        // re-seal
        let v2_blob = do_reseal(b"old-pass", b"new-pass", machine_id, &v1_blob).unwrap();

        // v2 blob であること
        assert_eq!(v2_blob[0], BLOB_V2);
        // 新パスフレーズで復号できること
        assert_eq!(do_unseal(b"new-pass", machine_id, &v2_blob).unwrap(), plaintext);
        // 旧パスフレーズでは復号できないこと
        assert!(matches!(
            do_unseal(b"old-pass", machine_id, &v2_blob),
            Err(CryptoError::DecryptFailed),
        ));
    }

    // ── 本番パラメータ確認（slow）──────────────────────────────────────────────

    #[test]
    #[ignore = "slow: production Argon2id params (64 MiB, ~1s per call)"]
    fn kdf_production_params_are_correct() {
        let salt = [0u8; 16];
        let key1 = derive_key(b"passphrase", Some(b"machine-id"), &salt).unwrap();
        let key2 = derive_key(b"passphrase", Some(b"machine-id"), &salt).unwrap();
        assert_eq!(key1.len(), 32);
        assert_eq!(key1, key2);
    }

    #[test]
    #[ignore = "slow: production Argon2id params (64 MiB)"]
    fn seal_unseal_production_params() {
        let blob   = seal(b"pass", Some(b"mid"), b"secret").unwrap();
        let result = unseal(b"pass", Some(b"mid"), &blob).unwrap();
        assert_eq!(result, b"secret");
    }
}

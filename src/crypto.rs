use argon2::{Algorithm, Argon2, Params, Version};
use zeroize::Zeroize;

// ── 定数 ─────────────────────────────────────────────────────────────────────

const ARGON2_M_COST: u32 = 65536; // 64 MiB
const ARGON2_T_COST: u32 = 3;
const ARGON2_P_COST: u32 = 1;

pub(crate) const KEY_LEN:  usize = 32;
pub(crate) const SALT_LEN: usize = 16;

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
}

// ── KDF ───────────────────────────────────────────────────────────────────────

/// Argon2id で 32 バイト鍵を導出する。
///
/// - Locked mode:   `password = passphrase ‖ 0x00 ‖ machine_id`
/// - Portable mode: `password = passphrase`（`machine_id = None`）
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
        ARGON2_M_COST,
        ARGON2_T_COST,
        ARGON2_P_COST,
        passphrase,
        machine_id,
        salt,
    )
}

// ── テスト ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// テスト用の軽量 Argon2id ラッパー（m=8KiB, t=1, p=1）
    fn kdf(passphrase: &[u8], machine_id: Option<&[u8]>, salt: &[u8; 16]) -> [u8; KEY_LEN] {
        derive_key_with_params(8, 1, 1, passphrase, machine_id, salt).unwrap()
    }

    // ── KDF パラメータ チェックリスト ──────────────────────────────────────────

    // [ ] 導出鍵は正確に 32 バイト
    #[test]
    fn kdf_output_is_32_bytes() {
        assert_eq!(kdf(b"pass", Some(b"mid"), &[0u8; 16]).len(), 32);
    }

    // [ ] 決定論的: 同じ入力 → 同じ出力
    #[test]
    fn kdf_is_deterministic() {
        let salt = [0x42u8; 16];
        assert_eq!(
            kdf(b"pass", Some(b"mid"), &salt),
            kdf(b"pass", Some(b"mid"), &salt),
        );
    }

    // [ ] Locked と Portable は異なる鍵を導出する
    #[test]
    fn locked_and_portable_produce_different_keys() {
        let salt = [0u8; 16];
        let locked   = kdf(b"pass", Some(b"mid"), &salt);
        let portable = kdf(b"pass", None, &salt);
        assert_ne!(locked, portable);
    }

    // [ ] null セパレータで長さ拡張攻撃を防ぐ
    //     "passA" + machine="B" != "pass" + machine="AB"
    #[test]
    fn null_separator_prevents_length_extension() {
        let salt = [0u8; 16];
        let key1 = kdf(b"passA", Some(b"B"),  &salt);
        let key2 = kdf(b"pass",  Some(b"AB"), &salt);
        assert_ne!(key1, key2);
    }

    // [ ] 異なる machine_id は異なる鍵を生成する
    #[test]
    fn different_machine_ids_produce_different_keys() {
        let salt = [0u8; 16];
        let key_a = kdf(b"pass", Some(b"machine-A"), &salt);
        let key_b = kdf(b"pass", Some(b"machine-B"), &salt);
        assert_ne!(key_a, key_b);
    }

    // [ ] 異なるソルトは異なる鍵を生成する
    #[test]
    fn different_salts_produce_different_keys() {
        let key1 = kdf(b"pass", Some(b"mid"), &[0u8; 16]);
        let key2 = kdf(b"pass", Some(b"mid"), &[1u8; 16]);
        assert_ne!(key1, key2);
    }

    // [ ] 本番パラメータ（m=64MiB, t=3, p=1）の動作確認
    //     cargo test -- --include-ignored で実行
    #[test]
    #[ignore = "slow: production Argon2id params (64 MiB, ~1s per call)"]
    fn kdf_production_params_are_correct() {
        let salt = [0u8; 16];
        let key1 = derive_key(b"passphrase", Some(b"machine-id"), &salt).unwrap();
        let key2 = derive_key(b"passphrase", Some(b"machine-id"), &salt).unwrap();
        assert_eq!(key1.len(), 32);
        assert_eq!(key1, key2);
    }
}

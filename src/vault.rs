use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use thiserror::Error;

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;

// O_NOFOLLOW — シンボリックリンク経由の open を拒否
#[cfg(target_os = "macos")]
const O_NOFOLLOW: i32 = 0x0000_0100;
#[cfg(target_os = "linux")]
const O_NOFOLLOW: i32 = 0x0002_0000;
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
const O_NOFOLLOW: i32 = 0;

#[derive(Debug, Error)]
pub enum VaultError {
    #[error("vault not found")]
    NotFound,
    #[error("vault is locked by another process")]
    Locked,
    #[error("corrupt vault: {0}")]
    Format(String),
    #[error("key '{0}' not found")]
    #[allow(dead_code)]
    KeyNotFound(String),
    #[error("key name must be 1..=255 bytes")]
    InvalidKeyName,
    #[error("i/o error: {0}")]
    Io(#[from] io::Error),
}

// --- バイナリ形式 ---
// 各エントリ: key_name_len(2B BE) | key_name(N) | blob_len(4B BE) | blob(M)

/// vault バイト列をエントリ列に分解する。
pub(crate) fn parse_entries(data: &[u8]) -> Result<Vec<(String, Vec<u8>)>, VaultError> {
    let mut entries = Vec::new();
    let mut pos = 0usize;
    while pos < data.len() {
        if pos + 2 > data.len() {
            return Err(VaultError::Format("truncated key_name_len".into()));
        }
        let key_len = u16::from_be_bytes([data[pos], data[pos + 1]]) as usize;
        pos += 2;
        if key_len == 0 || key_len > 255 {
            return Err(VaultError::Format(format!("invalid key_name_len: {}", key_len)));
        }
        if pos + key_len > data.len() {
            return Err(VaultError::Format("truncated key_name".into()));
        }
        let key = std::str::from_utf8(&data[pos..pos + key_len])
            .map_err(|_| VaultError::Format("key_name not valid UTF-8".into()))?
            .to_owned();
        pos += key_len;
        if pos + 4 > data.len() {
            return Err(VaultError::Format("truncated blob_len".into()));
        }
        let blob_len = u32::from_be_bytes([
            data[pos],
            data[pos + 1],
            data[pos + 2],
            data[pos + 3],
        ]) as usize;
        pos += 4;
        if pos + blob_len > data.len() {
            return Err(VaultError::Format("truncated blob".into()));
        }
        let blob = data[pos..pos + blob_len].to_vec();
        pos += blob_len;
        entries.push((key, blob));
    }
    Ok(entries)
}

/// エントリ列を vault バイト列にシリアライズする。
pub(crate) fn serialize_entries(entries: &[(String, Vec<u8>)]) -> Vec<u8> {
    let mut buf = Vec::new();
    for (key, blob) in entries {
        let kb = key.as_bytes();
        buf.extend_from_slice(&(kb.len() as u16).to_be_bytes());
        buf.extend_from_slice(kb);
        buf.extend_from_slice(&(blob.len() as u32).to_be_bytes());
        buf.extend_from_slice(blob);
    }
    buf
}

fn tmp_path(vault: &Path) -> PathBuf {
    let mut s = vault.as_os_str().to_owned();
    s.push(".tmp");
    PathBuf::from(s)
}

/// 新しい空の vault ファイルを作成する（mode 0600、冪等）。
#[allow(dead_code)]
pub fn init(path: &Path) -> Result<(), VaultError> {
    if path.exists() {
        return Ok(());
    }
    let mut opts = OpenOptions::new();
    opts.write(true).create_new(true);
    #[cfg(unix)]
    opts.mode(0o600);
    opts.open(path).map(|_| ()).map_err(VaultError::Io)
}

/// vault の全エントリを読み取る（shared ロック）。
#[allow(dead_code)]
pub fn read_entries(path: &Path) -> Result<Vec<(String, Vec<u8>)>, VaultError> {
    let mut opts = OpenOptions::new();
    opts.read(true);
    #[cfg(unix)]
    opts.custom_flags(O_NOFOLLOW);
    let mut file = opts.open(path).map_err(|e| {
        if e.kind() == io::ErrorKind::NotFound {
            VaultError::NotFound
        } else {
            VaultError::Io(e)
        }
    })?;
    file.lock_shared().map_err(|_| VaultError::Locked)?; // std 1.89+
    let mut data = Vec::new();
    file.read_to_end(&mut data).map_err(VaultError::Io)?;
    parse_entries(&data)
}

/// vault の全エントリをアトミックに書き換える（exclusive ロック + temp-file rename）。
#[allow(dead_code)]
pub fn write_entries(path: &Path, entries: &[(String, Vec<u8>)]) -> Result<(), VaultError> {
    for (key, _) in entries {
        let klen = key.len();
        if klen == 0 || klen > 255 {
            return Err(VaultError::InvalidKeyName);
        }
    }

    let mut lock_opts = OpenOptions::new();
    lock_opts.read(true).write(true).create(true);
    #[cfg(unix)]
    lock_opts.mode(0o600);
    let lock = lock_opts.open(path).map_err(VaultError::Io)?;
    lock.lock().map_err(|_| VaultError::Locked)?; // exclusive, std 1.89+

    let tmp = tmp_path(path);
    let data = serialize_entries(entries);
    {
        let mut tmp_opts = OpenOptions::new();
        tmp_opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        tmp_opts.mode(0o600);
        let mut f = tmp_opts.open(&tmp).map_err(VaultError::Io)?;
        f.write_all(&data).map_err(VaultError::Io)?;
        f.flush().map_err(VaultError::Io)?;
    }
    fs::rename(&tmp, path).map_err(VaultError::Io)?;
    drop(lock);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // ----------------------------------------------------------------
    // 純粋なフォーマットテスト（ファイル I/O なし）
    // ----------------------------------------------------------------

    #[test]
    fn parse_empty_returns_empty() {
        assert!(parse_entries(&[]).unwrap().is_empty());
    }

    #[test]
    fn roundtrip_single_entry() {
        let entries = vec![("mykey".to_owned(), vec![0xAA, 0xBB, 0xCC])];
        let data = serialize_entries(&entries);
        assert_eq!(parse_entries(&data).unwrap(), entries);
    }

    #[test]
    fn roundtrip_multiple_entries() {
        let entries = vec![
            ("alpha".to_owned(), vec![1, 2, 3]),
            ("beta".to_owned(), vec![4, 5, 6, 7]),
            ("gamma".to_owned(), vec![]),
        ];
        let data = serialize_entries(&entries);
        assert_eq!(parse_entries(&data).unwrap(), entries);
    }

    #[test]
    fn roundtrip_empty_blob() {
        let entries = vec![("k".to_owned(), vec![])];
        let data = serialize_entries(&entries);
        assert_eq!(parse_entries(&data).unwrap(), entries);
    }

    #[test]
    fn roundtrip_max_key_name_255_bytes() {
        let key = "x".repeat(255);
        let entries = vec![(key.clone(), vec![0u8])];
        let data = serialize_entries(&entries);
        assert_eq!(parse_entries(&data).unwrap()[0].0, key);
    }

    #[test]
    fn parse_truncated_at_key_name_len_fails() {
        // 1 バイトだけ — key_name_len(2B) が読めない
        assert!(parse_entries(&[0x00]).is_err());
    }

    #[test]
    fn parse_zero_key_len_fails() {
        let data = [0x00u8, 0x00]; // key_len = 0
        assert!(matches!(parse_entries(&data), Err(VaultError::Format(_))));
    }

    #[test]
    fn parse_key_len_256_fails() {
        // key_len = 256 → big-endian [0x01, 0x00]
        let data = [0x01u8, 0x00];
        assert!(matches!(parse_entries(&data), Err(VaultError::Format(_))));
    }

    #[test]
    fn parse_truncated_key_name_fails() {
        // key_len = 5 だが 3 バイトしかない
        let mut data = vec![0x00u8, 0x05];
        data.extend_from_slice(b"abc");
        assert!(matches!(parse_entries(&data), Err(VaultError::Format(_))));
    }

    #[test]
    fn parse_truncated_blob_len_fails() {
        // key は正常、blob_len に 3 バイトしかない（4 必要）
        let mut data = vec![0x00u8, 0x03];
        data.extend_from_slice(b"key");
        data.extend_from_slice(&[0x00, 0x00, 0x00]);
        assert!(matches!(parse_entries(&data), Err(VaultError::Format(_))));
    }

    #[test]
    fn parse_truncated_blob_fails() {
        // blob_len = 10 だが 3 バイトしかない
        let mut data = vec![0x00u8, 0x03];
        data.extend_from_slice(b"key");
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x0A]); // blob_len = 10
        data.extend_from_slice(&[0x01, 0x02, 0x03]);
        assert!(matches!(parse_entries(&data), Err(VaultError::Format(_))));
    }

    #[test]
    fn parse_invalid_utf8_key_name_fails() {
        let mut data = vec![0x00u8, 0x02]; // key_len = 2
        data.extend_from_slice(&[0xFF, 0xFE]); // invalid UTF-8
        data.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // blob_len = 0
        assert!(matches!(parse_entries(&data), Err(VaultError::Format(_))));
    }

    // ----------------------------------------------------------------
    // ファイル I/O テスト
    // ----------------------------------------------------------------

    #[test]
    fn init_creates_file() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        assert!(!path.exists());
        init(&path).unwrap();
        assert!(path.exists());
    }

    #[test]
    fn init_is_idempotent() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        init(&path).unwrap();
    }

    #[test]
    fn read_nonexistent_vault_returns_not_found() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("nonexistent.vault");
        assert!(matches!(read_entries(&path), Err(VaultError::NotFound)));
    }

    #[test]
    fn write_then_read_roundtrip() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        let entries = vec![
            ("secret1".to_owned(), vec![0xDE, 0xAD]),
            ("secret2".to_owned(), vec![0xBE, 0xEF]),
        ];
        write_entries(&path, &entries).unwrap();
        assert_eq!(read_entries(&path).unwrap(), entries);
    }

    #[test]
    fn write_replaces_existing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        write_entries(&path, &[("old".to_owned(), vec![1])]).unwrap();
        write_entries(&path, &[("new".to_owned(), vec![2])]).unwrap();
        let got = read_entries(&path).unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].0, "new");
    }

    #[test]
    fn write_empty_clears_vault() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        write_entries(&path, &[("k".to_owned(), vec![1])]).unwrap();
        write_entries(&path, &[]).unwrap();
        assert!(read_entries(&path).unwrap().is_empty());
    }

    #[test]
    fn write_rejects_empty_key_name() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        assert!(matches!(
            write_entries(&path, &[("".to_owned(), vec![])]),
            Err(VaultError::InvalidKeyName)
        ));
    }

    #[test]
    fn write_rejects_key_name_over_255() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        let key = "x".repeat(256);
        assert!(matches!(
            write_entries(&path, &[(key, vec![])]),
            Err(VaultError::InvalidKeyName)
        ));
    }

    #[cfg(unix)]
    #[test]
    fn init_sets_mode_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[cfg(unix)]
    #[test]
    fn write_preserves_mode_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.vault");
        init(&path).unwrap();
        write_entries(&path, &[("k".to_owned(), vec![1])]).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }
}

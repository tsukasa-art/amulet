#[cfg(any(target_os = "macos", target_os = "windows"))]
use std::process::Command;

use thiserror::Error;

#[derive(Debug, Error)]
pub enum MachineIdError {
    #[error("machine-id not found")]
    NotFound,
    #[error("machine-id is weak (all-zeros or empty) — vault binding refused")]
    Weak,
    #[error("failed to parse machine-id output")]
    #[allow(dead_code)]
    Parse,
    #[error("i/o error: {0}")]
    Io(#[from] std::io::Error),
}

// --- バリデーション（OS 非依存） ---

/// 生の machine-id 文字列をトリム・検証して bytes に変換する。
/// 空または全ゼロは Weak エラー。
pub(crate) fn validate(raw: &str) -> Result<Vec<u8>, MachineIdError> {
    let t = raw.trim();
    if t.is_empty() {
        return Err(MachineIdError::Weak);
    }
    // ダッシュを除いてすべて '0' なら all-zeros UUID / hex
    if t.replace('-', "").chars().all(|c| c == '0') {
        return Err(MachineIdError::Weak);
    }
    Ok(t.as_bytes().to_vec())
}

// --- macOS: ioreg パーサ ---

/// `ioreg -rd1 -c IOPlatformExpertDevice` の出力から IOPlatformUUID を抽出する。
#[cfg(target_os = "macos")]
pub(crate) fn parse_ioreg(output: &str) -> Option<String> {
    for line in output.lines() {
        if line.contains("IOPlatformUUID") {
            // 行例: `  "IOPlatformUUID" = "XXXX-..."`
            if let Some(pos) = line.rfind("= \"") {
                let rest = &line[pos + 3..];
                if let Some(end) = rest.find('"') {
                    let uuid = rest[..end].trim().to_owned();
                    if !uuid.is_empty() {
                        return Some(uuid);
                    }
                }
            }
        }
    }
    None
}

// --- Windows: reg query パーサ ---

/// `reg query HKLM\...\Cryptography /v MachineGuid` の出力から GUID を抽出する。
#[cfg(target_os = "windows")]
pub(crate) fn parse_reg_query(output: &str) -> Option<String> {
    for line in output.lines() {
        if line.trim_start().starts_with("MachineGuid") {
            // 行例: `    MachineGuid    REG_SZ    XXXX-...`
            let parts: Vec<&str> = line.split_whitespace().collect();
            if parts.len() >= 3 {
                return Some(parts[parts.len() - 1].to_owned());
            }
        }
    }
    None
}

// --- OS 別の生取得 ---

#[cfg(target_os = "macos")]
fn fetch_raw() -> Result<String, MachineIdError> {
    let out = Command::new("ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .output()
        .map_err(MachineIdError::Io)?;
    if !out.status.success() {
        return Err(MachineIdError::NotFound);
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    parse_ioreg(&stdout).ok_or(MachineIdError::Parse)
}

#[cfg(target_os = "linux")]
fn fetch_raw() -> Result<String, MachineIdError> {
    const PATHS: &[&str] = &["/etc/machine-id", "/var/lib/dbus/machine-id"];
    for path in PATHS {
        match std::fs::read_to_string(path) {
            Ok(s) => return Ok(s),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(MachineIdError::Io(e)),
        }
    }
    Err(MachineIdError::NotFound)
}

#[cfg(target_os = "windows")]
fn fetch_raw() -> Result<String, MachineIdError> {
    let out = Command::new("reg")
        .args([
            "query",
            r"HKLM\SOFTWARE\Microsoft\Cryptography",
            "/v",
            "MachineGuid",
        ])
        .output()
        .map_err(MachineIdError::Io)?;
    if !out.status.success() {
        return Err(MachineIdError::NotFound);
    }
    let stdout = String::from_utf8_lossy(&out.stdout);
    parse_reg_query(&stdout).ok_or(MachineIdError::Parse)
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn fetch_raw() -> Result<String, MachineIdError> {
    Err(MachineIdError::NotFound)
}

/// マシン固有の ID をバイト列で返す（トリム・検証済み）。
/// 取得失敗・弱い値の場合は Err を返す（呼び出し元が exit するかを決める）。
#[allow(dead_code)]
pub fn get() -> Result<Vec<u8>, MachineIdError> {
    let raw = fetch_raw()?;
    validate(&raw)
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- validate ---

    #[test]
    fn validate_trims_trailing_newline() {
        let id = validate("b08d74ab4f3e4a8392c4dbc654f5d5a3\n").unwrap();
        assert_eq!(id, b"b08d74ab4f3e4a8392c4dbc654f5d5a3");
    }

    #[test]
    fn validate_trims_surrounding_whitespace() {
        let id = validate("  abc123  \n").unwrap();
        assert_eq!(id, b"abc123");
    }

    #[test]
    fn validate_empty_is_weak() {
        assert!(matches!(validate(""), Err(MachineIdError::Weak)));
    }

    #[test]
    fn validate_whitespace_only_is_weak() {
        assert!(matches!(validate("   \n\t"), Err(MachineIdError::Weak)));
    }

    #[test]
    fn validate_all_zeros_hex_is_weak() {
        assert!(matches!(
            validate("00000000000000000000000000000000"),
            Err(MachineIdError::Weak)
        ));
    }

    #[test]
    fn validate_all_zeros_uuid_is_weak() {
        assert!(matches!(
            validate("00000000-0000-0000-0000-000000000000"),
            Err(MachineIdError::Weak)
        ));
    }

    #[test]
    fn validate_normal_linux_id() {
        let id = validate("b08d74ab4f3e4a8392c4dbc654f5d5a3\n").unwrap();
        assert_eq!(id, b"b08d74ab4f3e4a8392c4dbc654f5d5a3");
    }

    #[test]
    fn validate_normal_uuid() {
        let id = validate("6BA7B810-9DAD-11D1-80B4-00C04FD430C8").unwrap();
        assert_eq!(id, b"6BA7B810-9DAD-11D1-80B4-00C04FD430C8");
    }

    #[test]
    fn validate_non_zero_uuid_is_accepted() {
        // 1文字でも非ゼロがあれば OK
        let id = validate("00000000-0000-0000-0000-000000000001").unwrap();
        assert!(!id.is_empty());
    }

    // --- macOS ioreg パーサ ---

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_ioreg_extracts_uuid() {
        let sample = r#"+-o Root  <class IORegistryEntry>
  {
    "IOPlatformSerialNumber" = "C02XY1234AB"
    "IOPlatformUUID" = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
  }"#;
        assert_eq!(
            parse_ioreg(sample).unwrap(),
            "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_ioreg_missing_uuid_returns_none() {
        let sample = r#"  "IOPlatformSerialNumber" = "C02XY1234AB""#;
        assert!(parse_ioreg(sample).is_none());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn parse_ioreg_empty_output_returns_none() {
        assert!(parse_ioreg("").is_none());
    }

    // --- Windows reg query パーサ ---

    #[cfg(target_os = "windows")]
    #[test]
    fn parse_reg_query_extracts_guid() {
        let sample = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\n    MachineGuid    REG_SZ    6BA7B810-9DAD-11D1-80B4-00C04FD430C8\n";
        assert_eq!(
            parse_reg_query(sample).unwrap(),
            "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
        );
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn parse_reg_query_missing_key_returns_none() {
        let sample = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Cryptography\n";
        assert!(parse_reg_query(sample).is_none());
    }

    // --- integration: get() ---

    #[test]
    fn get_returns_nonempty_bytes_or_not_found() {
        match get() {
            Ok(id) => assert!(!id.is_empty(), "machine-id must not be empty"),
            Err(MachineIdError::NotFound) => {
                // CI 環境など取得できない場合は許容
                eprintln!("SKIP: machine-id not available in this environment");
            }
            Err(e) => panic!("unexpected error: {e}"),
        }
    }
}

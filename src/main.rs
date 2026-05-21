mod crypto;
mod machine_id;
mod vault;

use std::io::{self, Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::process;

use clap::{Parser, Subcommand};
use zeroize::Zeroize;

const DEFAULT_VAULT: &str = "amulet.vault";
const MAX_PASSPHRASE_LEN: usize = 1024;
const WIPE_COMMENT_MARKER: &str = "# plaintext values wiped by amulet";

// ── Release: panic → silent exit(1) ──────────────────────────────────────────

#[cfg(not(debug_assertions))]
fn install_panic_hook() {
    std::panic::set_hook(Box::new(|_| process::exit(1)));
}
#[cfg(debug_assertions)]
fn install_panic_hook() {}

// ── CLI ────────────────────────────────────────────────────────────────────────

#[derive(Parser)]
#[command(name = "amulet", disable_help_flag = true, disable_version_flag = true)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    Help,
    Version,
    Probe,
    Init {
        #[arg(long)]
        file: Option<PathBuf>,
    },
    List {
        #[arg(long)]
        file: Option<PathBuf>,
    },
    Delete {
        key: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    Rename {
        old: String,
        #[arg(name = "new")]
        new_key: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    Seal {
        #[arg(long)]
        portable: bool,
        key: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    Unseal {
        #[arg(long)]
        tty: bool,
        key: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    Verify {
        #[arg(long)]
        tty: bool,
        key: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    #[command(name = "re-seal")]
    Reseal {
        key: String,
        #[arg(long)]
        file: Option<PathBuf>,
    },
    Import {
        #[arg(long = "env-file")]
        env_file: PathBuf,
        #[arg(long)]
        portable: bool,
        #[arg(long)]
        manifest: Option<PathBuf>,
        #[arg(long)]
        wipe: bool,
        #[arg(long = "wipe-comment")]
        wipe_comment: bool,
        #[arg(long)]
        file: Option<PathBuf>,
    },
}

// ── main ───────────────────────────────────────────────────────────────────────

fn main() {
    install_panic_hook();

    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        None => {
            eprint!("{}", usage_text());
            process::exit(2);
        }
        Some("help" | "-h" | "--help") => {
            print!("{}", usage_text());
            process::exit(0);
        }
        _ => {}
    }

    let cli = match Cli::try_parse() {
        Ok(c) => c,
        Err(_) => {
            eprint!("{}", usage_text());
            process::exit(2);
        }
    };

    process::exit(dispatch(cli.command));
}

fn vault_path(flag: Option<PathBuf>) -> PathBuf {
    flag.unwrap_or_else(|| PathBuf::from(DEFAULT_VAULT))
}

fn dispatch(cmd: Cmd) -> i32 {
    match cmd {
        Cmd::Help => {
            print!("{}", usage_text());
            0
        }
        Cmd::Version => cmd_version(),
        Cmd::Probe => cmd_probe(),
        Cmd::Init { file } => cmd_init(&vault_path(file)),
        Cmd::List { file } => cmd_list(&vault_path(file)),
        Cmd::Delete { key, file } => cmd_delete(&key, &vault_path(file)),
        Cmd::Rename { old, new_key, file } => cmd_rename(&old, &new_key, &vault_path(file)),
        Cmd::Seal { portable, key, file } => cmd_seal(portable, &key, &vault_path(file)),
        Cmd::Unseal { tty, key, file } => cmd_unseal(tty, &key, &vault_path(file)),
        Cmd::Verify { tty, key, file } => cmd_verify(tty, &key, &vault_path(file)),
        Cmd::Reseal { key, file } => cmd_reseal(&key, &vault_path(file)),
        Cmd::Import {
            env_file,
            portable,
            manifest,
            wipe,
            wipe_comment,
            file,
        } => cmd_import(
            &env_file,
            portable,
            manifest.as_deref(),
            wipe,
            wipe_comment,
            &vault_path(file),
        ),
    }
}

// ── version / probe ───────────────────────────────────────────────────────────

fn cmd_version() -> i32 {
    println!("{}", env!("CARGO_PKG_VERSION"));
    0
}

fn cmd_probe() -> i32 {
    match machine_id::get() {
        Ok(id) => {
            let _ = io::stdout().write_all(&id);
            let _ = io::stdout().write_all(b"\n");
            0
        }
        Err(machine_id::MachineIdError::NotFound) => 2,
        Err(_) => 1,
    }
}

// ── init ──────────────────────────────────────────────────────────────────────

fn cmd_init(path: &Path) -> i32 {
    if path.exists() {
        eprintln!("init failed: vault already exists: {}", path.display());
        return 1;
    }
    match vault::init(path) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("init failed: {e}");
            1
        }
    }
}

// ── list ──────────────────────────────────────────────────────────────────────

fn cmd_list(path: &Path) -> i32 {
    match vault::read_entries(path) {
        Ok(entries) => {
            let stdout = io::stdout();
            let mut out = stdout.lock();
            for (key, _) in &entries {
                let _ = writeln!(out, "{key}");
            }
            0
        }
        Err(_) => 1,
    }
}

// ── delete ────────────────────────────────────────────────────────────────────

fn cmd_delete(key: &str, path: &Path) -> i32 {
    if key.is_empty() || key.len() > 255 {
        eprint!("{}", usage_text());
        return 2;
    }
    let mut entries = match vault::read_entries(path) {
        Ok(e) => e,
        Err(_) => return 1,
    };
    let before = entries.len();
    entries.retain(|(k, _)| k != key);
    if entries.len() == before {
        return 1;
    }
    match vault::write_entries(path, &entries) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

// ── rename ────────────────────────────────────────────────────────────────────

#[derive(Debug)]
#[allow(dead_code)]
pub(crate) enum RenameError {
    Vault(vault::VaultError),
    OldKeyNotFound,
    NewKeyAlreadyExists,
}

pub(crate) fn rename_entry(path: &Path, old: &str, new: &str) -> Result<(), RenameError> {
    let mut entries = vault::read_entries(path).map_err(RenameError::Vault)?;
    let mut old_idx: Option<usize> = None;
    for (i, (k, _)) in entries.iter().enumerate() {
        if k == new {
            return Err(RenameError::NewKeyAlreadyExists);
        }
        if k == old {
            old_idx = Some(i);
        }
    }
    entries[old_idx.ok_or(RenameError::OldKeyNotFound)?].0 = new.to_owned();
    vault::write_entries(path, &entries).map_err(RenameError::Vault)
}

fn cmd_rename(old: &str, new: &str, path: &Path) -> i32 {
    if old.is_empty() || old.len() > 255 || new.is_empty() || new.len() > 255 {
        eprint!("{}", usage_text());
        return 2;
    }
    match rename_entry(path, old, new) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

// ── secure I/O ────────────────────────────────────────────────────────────────

fn mlock_warn(buf: &mut [u8]) {
    if buf.is_empty() {
        return;
    }
    unsafe {
        if !memsec::mlock(buf.as_mut_ptr(), buf.len()) {
            eprintln!("warning: mlock failed, secrets may appear in swap");
        }
    }
}

fn munlock_silent(buf: &mut [u8]) {
    if !buf.is_empty() {
        unsafe {
            memsec::munlock(buf.as_mut_ptr(), buf.len());
        }
    }
}

#[cfg(unix)]
fn read_passphrase_tty(prompt: &str) -> Vec<u8> {
    use std::os::unix::io::AsRawFd;

    let mut tty = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open("/dev/tty")
        .unwrap_or_else(|_| {
            eprintln!("error: cannot open /dev/tty");
            process::exit(1);
        });
    let fd = tty.as_raw_fd();

    let mut old: libc::termios = unsafe { std::mem::zeroed() };
    if unsafe { libc::tcgetattr(fd, &mut old) } != 0 {
        eprintln!("error: cannot get terminal attributes");
        process::exit(1);
    }

    struct RestoreTty {
        fd: std::ffi::c_int,
        saved: libc::termios,
    }
    impl Drop for RestoreTty {
        fn drop(&mut self) {
            unsafe {
                libc::tcsetattr(self.fd, libc::TCSAFLUSH, &self.saved);
            }
        }
    }

    let mut new_t = old;
    new_t.c_lflag &= !(libc::ECHO | libc::ECHONL);
    if unsafe { libc::tcsetattr(fd, libc::TCSAFLUSH, &new_t) } != 0 {
        eprintln!("error: cannot disable echo");
        process::exit(1);
    }
    let _restore = RestoreTty { fd, saved: old };

    let _ = tty.write_all(prompt.as_bytes());
    let _ = tty.flush();

    let mut buf: Vec<u8> = Vec::with_capacity(64);
    let mut byte = [0u8; 1];
    loop {
        match tty.read(&mut byte) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                if byte[0] == b'\n' || byte[0] == b'\r' {
                    break;
                }
                if buf.len() < MAX_PASSPHRASE_LEN {
                    buf.push(byte[0]);
                }
            }
        }
    }
    let _ = tty.write_all(b"\n");

    mlock_warn(&mut buf);
    buf
}

#[cfg(not(unix))]
fn read_passphrase_tty(prompt: &str) -> Vec<u8> {
    eprint!("{prompt}");
    read_stdin_line()
}

fn read_stdin_line() -> Vec<u8> {
    let mut buf: Vec<u8> = Vec::new();
    for byte in io::stdin().lock().bytes() {
        match byte {
            Ok(b'\n') | Err(_) => break,
            Ok(b'\r') => {}
            Ok(b) => {
                if buf.len() < MAX_PASSPHRASE_LEN {
                    buf.push(b);
                }
            }
        }
    }
    mlock_warn(&mut buf);
    buf
}

fn read_stdin_secret() -> Vec<u8> {
    let mut buf = Vec::new();
    let _ = io::stdin()
        .lock()
        .take(crypto::MAX_SECRET_LEN as u64)
        .read_to_end(&mut buf);
    mlock_warn(&mut buf);
    buf
}

// ── seal ──────────────────────────────────────────────────────────────────────

fn cmd_seal(portable: bool, key: &str, path: &Path) -> i32 {
    if key.is_empty() || key.len() > 255 {
        eprint!("{}", usage_text());
        return 2;
    }
    if portable {
        eprintln!("WARNING: portable mode reduces security");
    }

    let mut passphrase = read_passphrase_tty("Passphrase: ");
    let mut secret = read_stdin_secret();

    let machine_id = if portable {
        None
    } else {
        match machine_id::get() {
            Ok(id) => Some(id),
            Err(_) => {
                eprintln!("seal failed: cannot retrieve machine ID");
                munlock_silent(&mut passphrase);
                passphrase.zeroize();
                munlock_silent(&mut secret);
                secret.zeroize();
                return 1;
            }
        }
    };

    let blob = crypto::seal(&passphrase, machine_id.as_deref(), &secret);
    munlock_silent(&mut passphrase);
    passphrase.zeroize();
    munlock_silent(&mut secret);
    secret.zeroize();

    let blob = match blob {
        Ok(b) => b,
        Err(_) => return 1,
    };

    let mut entries = match vault::read_entries(path) {
        Ok(e) => e,
        Err(vault::VaultError::NotFound) => Vec::new(),
        Err(_) => return 1,
    };
    match entries.iter_mut().find(|(k, _)| k == key) {
        Some(e) => e.1 = blob,
        None => entries.push((key.to_owned(), blob)),
    }
    match vault::write_entries(path, &entries) {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

// ── unseal ────────────────────────────────────────────────────────────────────

fn cmd_unseal(use_tty: bool, key: &str, path: &Path) -> i32 {
    if key.is_empty() || key.len() > 255 {
        return 1;
    }

    let mut passphrase = if use_tty {
        read_passphrase_tty("Passphrase: ")
    } else {
        read_stdin_line()
    };

    let machine_id = machine_id::get().ok();

    let entries = match vault::read_entries(path) {
        Ok(e) => e,
        Err(_) => {
            munlock_silent(&mut passphrase);
            passphrase.zeroize();
            return 1;
        }
    };

    let blob = match entries.iter().find(|(k, _)| k == key) {
        Some((_, b)) => b.clone(),
        None => {
            munlock_silent(&mut passphrase);
            passphrase.zeroize();
            return 1;
        }
    };

    let mut plaintext = match crypto::unseal(&passphrase, machine_id.as_deref(), &blob) {
        Ok(pt) => pt,
        Err(_) => {
            munlock_silent(&mut passphrase);
            passphrase.zeroize();
            return 1;
        }
    };
    munlock_silent(&mut passphrase);
    passphrase.zeroize();

    let _ = io::stdout().write_all(&plaintext);
    munlock_silent(&mut plaintext);
    plaintext.zeroize();
    0
}

// ── verify ────────────────────────────────────────────────────────────────────

#[derive(Debug)]
#[allow(dead_code)]
pub(crate) enum VerifyError {
    Vault(vault::VaultError),
    KeyNotFound,
    Crypto(crypto::CryptoError),
}

pub(crate) fn verify_entry(
    path: &Path,
    key: &str,
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
) -> Result<(), VerifyError> {
    let entries = vault::read_entries(path).map_err(VerifyError::Vault)?;
    let blob = entries
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, b)| b.as_slice())
        .ok_or(VerifyError::KeyNotFound)?;
    let mut pt = crypto::unseal(passphrase, machine_id, blob).map_err(VerifyError::Crypto)?;
    pt.zeroize();
    Ok(())
}

fn cmd_verify(use_tty: bool, key: &str, path: &Path) -> i32 {
    let mut passphrase = if use_tty {
        read_passphrase_tty("Passphrase: ")
    } else {
        read_stdin_line()
    };
    let machine_id = machine_id::get().ok();
    let result = verify_entry(path, key, &passphrase, machine_id.as_deref());
    munlock_silent(&mut passphrase);
    passphrase.zeroize();
    match result {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

// ── re-seal ───────────────────────────────────────────────────────────────────

#[derive(Debug)]
#[allow(dead_code)]
pub(crate) enum ResealError {
    Vault(vault::VaultError),
    KeyNotFound,
    Crypto(crypto::CryptoError),
}

pub(crate) fn reseal_entry(
    path: &Path,
    key: &str,
    old_pass: &[u8],
    new_pass: &[u8],
    machine_id: Option<&[u8]>,
) -> Result<(), ResealError> {
    let mut entries = vault::read_entries(path).map_err(ResealError::Vault)?;
    let blob = entries
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, b)| b.clone())
        .ok_or(ResealError::KeyNotFound)?;
    let new_blob =
        crypto::reseal(old_pass, new_pass, machine_id, &blob).map_err(ResealError::Crypto)?;
    if let Some(e) = entries.iter_mut().find(|(k, _)| k == key) {
        e.1 = new_blob;
    }
    vault::write_entries(path, &entries).map_err(ResealError::Vault)
}

fn cmd_reseal(key: &str, path: &Path) -> i32 {
    if key.is_empty() || key.len() > 255 {
        eprint!("{}", usage_text());
        return 2;
    }
    let mut old_pass = read_passphrase_tty("Current passphrase: ");
    let mut new_pass = read_passphrase_tty("New passphrase: ");
    let mut confirm = read_passphrase_tty("Confirm new passphrase: ");

    if new_pass != confirm {
        eprintln!("re-seal failed: new passphrases do not match");
        munlock_silent(&mut old_pass);
        old_pass.zeroize();
        munlock_silent(&mut new_pass);
        new_pass.zeroize();
        munlock_silent(&mut confirm);
        confirm.zeroize();
        return 1;
    }
    munlock_silent(&mut confirm);
    confirm.zeroize();

    let machine_id = machine_id::get().ok();
    let result = reseal_entry(path, key, &old_pass, &new_pass, machine_id.as_deref());
    munlock_silent(&mut old_pass);
    old_pass.zeroize();
    munlock_silent(&mut new_pass);
    new_pass.zeroize();
    match result {
        Ok(()) => 0,
        Err(_) => 1,
    }
}

// ── import helpers ────────────────────────────────────────────────────────────

/// Parse KEY=VALUE lines. Blank lines and `#` comments are skipped.
pub(crate) fn parse_env_pairs(content: &str) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    for raw in content.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some(eq) = line.find('=') else { continue };
        let key = line[..eq].trim();
        if key.is_empty() || key.len() > 255 {
            continue;
        }
        pairs.push((key.to_owned(), line[eq + 1..].to_owned()));
    }
    pairs
}

/// Seal each pair into the vault (upsert). Creates vault if missing.
pub(crate) fn import_pairs(
    path: &Path,
    pairs: &[(String, String)],
    passphrase: &[u8],
    machine_id: Option<&[u8]>,
    portable: bool,
) -> Result<(), vault::VaultError> {
    let mut entries = match vault::read_entries(path) {
        Ok(e) => e,
        Err(vault::VaultError::NotFound) => Vec::new(),
        Err(e) => return Err(e),
    };
    for (key, value) in pairs {
        let blob = crypto::seal(passphrase, if portable { None } else { machine_id }, value.as_bytes())
            .map_err(|_| vault::VaultError::Io(io::Error::new(io::ErrorKind::Other, "crypto")))?;
        match entries.iter_mut().find(|(k, _)| k == key) {
            Some(e) => e.1 = blob,
            None => entries.push((key.clone(), blob)),
        }
    }
    vault::write_entries(path, &entries)
}

/// Overwrite value portions of KEY=VALUE lines with spaces (in-place).
fn wipe_env_values(path: &Path, original: &str) -> io::Result<()> {
    let mut file = std::fs::OpenOptions::new().write(true).open(path)?;
    let mut offset: u64 = 0;
    for raw_line in original.split('\n') {
        let trimmed = raw_line.trim_end_matches('\r');
        if let Some(eq) = trimmed.find('=') {
            let value_len = trimmed.len() - (eq + 1);
            if value_len > 0 {
                file.seek(io::SeekFrom::Start(offset + (eq + 1) as u64))?;
                file.write_all(&vec![b' '; value_len])?;
            }
        }
        offset += raw_line.len() as u64 + 1; // +1 for '\n'
    }
    Ok(())
}

pub(crate) fn has_wipe_comment(content: &str) -> bool {
    content.lines().any(|l| l.trim() == WIPE_COMMENT_MARKER)
}

pub(crate) fn append_wipe_comment(path: &Path) -> io::Result<()> {
    let content = std::fs::read_to_string(path)?;
    if has_wipe_comment(&content) {
        return Ok(());
    }
    let mut file = std::fs::OpenOptions::new().append(true).open(path)?;
    if !content.is_empty() && !content.ends_with('\n') {
        file.write_all(b"\n")?;
    }
    file.write_all(WIPE_COMMENT_MARKER.as_bytes())?;
    file.write_all(b"\n")
}

fn cmd_import(
    env_path: &Path,
    portable: bool,
    manifest: Option<&Path>,
    wipe: bool,
    wipe_comment: bool,
    vault_p: &Path,
) -> i32 {
    if wipe_comment && !wipe {
        eprint!("{}", usage_text());
        return 2;
    }
    if portable {
        eprintln!("WARNING: portable mode reduces security");
    }

    let mut passphrase = read_passphrase_tty("Passphrase: ");

    let machine_id = if portable {
        None
    } else {
        match machine_id::get() {
            Ok(id) => Some(id),
            Err(_) => {
                eprintln!("import failed: cannot retrieve machine ID");
                munlock_silent(&mut passphrase);
                passphrase.zeroize();
                return 1;
            }
        }
    };

    let content = match std::fs::read_to_string(env_path) {
        Ok(c) => c,
        Err(_) => {
            eprintln!("import failed: cannot read {}", env_path.display());
            munlock_silent(&mut passphrase);
            passphrase.zeroize();
            return 1;
        }
    };

    let pairs = parse_env_pairs(&content);
    if pairs.is_empty() {
        eprintln!("import: no KEY=VALUE entries found in {}", env_path.display());
        munlock_silent(&mut passphrase);
        passphrase.zeroize();
        return 1;
    }

    if import_pairs(vault_p, &pairs, &passphrase, machine_id.as_deref(), portable).is_err() {
        munlock_silent(&mut passphrase);
        passphrase.zeroize();
        return 1;
    }
    munlock_silent(&mut passphrase);
    passphrase.zeroize();

    if let Some(mpath) = manifest {
        match std::fs::File::create(mpath) {
            Ok(mut f) => {
                for (key, _) in &pairs {
                    let _ = writeln!(f, "{key}");
                }
            }
            Err(_) => {
                eprintln!("import: could not write manifest {}", mpath.display());
                return 1;
            }
        }
    }

    if wipe {
        if wipe_env_values(env_path, &content).is_err() {
            eprintln!(
                "import: vault written but wipe of {} failed — plaintext may remain",
                env_path.display()
            );
            return 1;
        }
        if wipe_comment && append_wipe_comment(env_path).is_err() {
            eprintln!("import: vault written and wiped but appending wipe marker failed");
            return 1;
        }
    }
    0
}

// ── usage ─────────────────────────────────────────────────────────────────────

fn usage_text() -> &'static str {
    "\
Usage:
  amulet help | -h | --help
  amulet version
  amulet probe
  amulet list                            [--file <vault>]
  amulet delete             <key>        [--file <vault>]
  amulet rename             <old> <new>  [--file <vault>]
  amulet init                            [--file <vault>]
  amulet seal   [--portable] <key>       [--file <vault>]
  amulet unseal [--tty]      <key>       [--file <vault>]
  amulet verify [--tty]      <key>       [--file <vault>]
  amulet re-seal             <key>       [--file <vault>]
  amulet import  --env-file <path> [--portable] [--manifest <path>] [--wipe] [--wipe-comment] [--file <vault>]

  list:    key names only (one per line), no passphrase
  delete:  remove one key from the vault (passphrase not required)
  rename:  rename a key in the vault index (no passphrase, no re-encryption)
  probe:   print machine ID for this host (same source as Locked-mode seal)
  seal:    passphrase prompted from /dev/tty (echo off), secret read from stdin
  unseal:  passphrase read from stdin (first line); use --tty for interactive echo-off prompt
  verify:  same as unseal but produces no output — exit 0 = correct passphrase, exit 1 = wrong
  re-seal: change the passphrase for one key; prompts current + new + confirm from /dev/tty
  import:  bulk-seal from a .env file (KEY=VALUE lines); --wipe overwrites values after import;
           optional --wipe-comment (requires --wipe) appends a marker line to the .env file
"
}

// ── tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_vault(dir: &TempDir, key: &str, value: &[u8], passphrase: &[u8]) -> PathBuf {
        let path = dir.path().join("t.vault");
        vault::init(&path).unwrap();
        let blob = crypto::seal(passphrase, None, value).unwrap();
        vault::write_entries(&path, &[(key.to_owned(), blob)]).unwrap();
        path
    }

    // --- rename_entry ---

    #[test]
    fn rename_changes_key_name() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "OLD", b"secret", b"pass");
        rename_entry(&path, "OLD", "NEW").unwrap();
        let entries = vault::read_entries(&path).unwrap();
        assert_eq!(entries[0].0, "NEW");
    }

    #[test]
    fn rename_blob_preserved() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "OLD", b"secret", b"pass");
        let original_blob = vault::read_entries(&path).unwrap()[0].1.clone();
        rename_entry(&path, "OLD", "NEW").unwrap();
        let entries = vault::read_entries(&path).unwrap();
        assert_eq!(entries[0].1, original_blob);
    }

    #[test]
    fn rename_old_key_not_found() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"val", b"pass");
        assert!(matches!(
            rename_entry(&path, "MISSING", "NEW"),
            Err(RenameError::OldKeyNotFound)
        ));
    }

    #[test]
    fn rename_new_key_already_exists() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("t.vault");
        vault::init(&path).unwrap();
        let b1 = crypto::seal(b"p", None, b"v").unwrap();
        let b2 = crypto::seal(b"p", None, b"v").unwrap();
        vault::write_entries(&path, &[("A".to_owned(), b1), ("B".to_owned(), b2)]).unwrap();
        assert!(matches!(
            rename_entry(&path, "A", "B"),
            Err(RenameError::NewKeyAlreadyExists)
        ));
    }

    // --- verify_entry ---

    #[test]
    fn verify_correct_passphrase() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"secret", b"right");
        assert!(verify_entry(&path, "KEY", b"right", None).is_ok());
    }

    #[test]
    fn verify_wrong_passphrase() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"secret", b"right");
        assert!(matches!(
            verify_entry(&path, "KEY", b"wrong", None),
            Err(VerifyError::Crypto(_))
        ));
    }

    #[test]
    fn verify_key_not_found() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"secret", b"pass");
        assert!(matches!(
            verify_entry(&path, "MISSING", b"pass", None),
            Err(VerifyError::KeyNotFound)
        ));
    }

    // --- reseal_entry ---

    #[test]
    fn reseal_new_passphrase_works_old_fails() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"secret", b"old");
        reseal_entry(&path, "KEY", b"old", b"new", None).unwrap();
        assert!(verify_entry(&path, "KEY", b"new", None).is_ok());
        assert!(verify_entry(&path, "KEY", b"old", None).is_err());
    }

    #[test]
    fn reseal_preserves_plaintext() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"my-secret", b"old");
        reseal_entry(&path, "KEY", b"old", b"new", None).unwrap();
        let entries = vault::read_entries(&path).unwrap();
        let pt = crypto::unseal(b"new", None, &entries[0].1).unwrap();
        assert_eq!(pt, b"my-secret");
    }

    // --- parse_env_pairs ---

    #[test]
    fn parse_env_basic_kv() {
        let pairs = parse_env_pairs("FOO=bar\nBAZ=qux\n");
        assert_eq!(pairs.len(), 2);
        assert_eq!(pairs[0], ("FOO".to_owned(), "bar".to_owned()));
        assert_eq!(pairs[1], ("BAZ".to_owned(), "qux".to_owned()));
    }

    #[test]
    fn parse_env_skips_comments_and_blanks() {
        let pairs = parse_env_pairs("# comment\n\nKEY=val\n");
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].0, "KEY");
    }

    #[test]
    fn parse_env_embedded_equals() {
        let pairs = parse_env_pairs("KEY=a=b=c\n");
        assert_eq!(pairs[0].1, "a=b=c");
    }

    #[test]
    fn parse_env_empty() {
        assert!(parse_env_pairs("").is_empty());
    }

    // --- wipe comment ---

    #[test]
    fn has_wipe_comment_false_when_absent() {
        assert!(!has_wipe_comment("KEY=val\n"));
    }

    #[test]
    fn has_wipe_comment_true_when_present() {
        let content = format!("KEY=val\n{WIPE_COMMENT_MARKER}\n");
        assert!(has_wipe_comment(&content));
    }

    #[test]
    fn append_wipe_comment_adds_marker() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.env");
        std::fs::write(&path, "FOO=bar\n").unwrap();
        append_wipe_comment(&path).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.ends_with(&format!("{WIPE_COMMENT_MARKER}\n")));
    }

    #[test]
    fn append_wipe_comment_idempotent() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.env");
        let initial = format!("FOO=bar\n{WIPE_COMMENT_MARKER}\n");
        std::fs::write(&path, &initial).unwrap();
        append_wipe_comment(&path).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), initial);
    }

    #[test]
    fn append_wipe_comment_inserts_newline_when_missing() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("test.env");
        std::fs::write(&path, "FOO=bar").unwrap();
        append_wipe_comment(&path).unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert_eq!(content, format!("FOO=bar\n{WIPE_COMMENT_MARKER}\n"));
    }

    // --- import_pairs ---

    #[test]
    fn import_pairs_seals_entries() {
        let dir = TempDir::new().unwrap();
        let path = dir.path().join("t.vault");
        vault::init(&path).unwrap();
        let pairs = vec![
            ("FOO".to_owned(), "hello".to_owned()),
            ("BAR".to_owned(), "world".to_owned()),
        ];
        import_pairs(&path, &pairs, b"pass", None, true).unwrap();
        assert_eq!(vault::read_entries(&path).unwrap().len(), 2);
    }

    #[test]
    fn import_pairs_overwrites_existing() {
        let dir = TempDir::new().unwrap();
        let path = make_vault(&dir, "KEY", b"old", b"pass");
        import_pairs(
            &path,
            &[("KEY".to_owned(), "new".to_owned())],
            b"pass",
            None,
            true,
        )
        .unwrap();
        let entries = vault::read_entries(&path).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(crypto::unseal(b"pass", None, &entries[0].1).unwrap(), b"new");
    }
}

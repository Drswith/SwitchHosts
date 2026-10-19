fn main() {
    // Same version source as the Tauri app (`src/version.json`) so the
    // User-Agent and version strings stay identical for both hosts.
    let version_path = std::path::Path::new("../../src/version.json");
    println!("cargo:rerun-if-changed={}", version_path.display());

    let content = std::fs::read_to_string(version_path)
        .expect("failed to read src/version.json — is it present at the repo root?");
    let version: String = serde_json::from_str(&content)
        .expect("src/version.json must be a JSON string like \"5.0.0\"");

    println!("cargo:rustc-env=SWH_VERSION={version}");

    // Build scripts run on the host, so check the target OS from Cargo.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-lib=framework=Security");
        // ServiceManagement: SMAppService daemon registration (the
        // privileged helper install path). See hosts_apply::helper_admin.
        println!("cargo:rustc-link-lib=framework=ServiceManagement");
    }
}

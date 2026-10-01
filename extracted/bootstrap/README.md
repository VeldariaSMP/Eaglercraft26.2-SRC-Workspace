# App-local toolchain bootstrap

Platform launchers live here. Use `launch-gui-linux-x86_64.sh` on Linux,
`macos/launch-gui-macos.command` on macOS 13+ Intel/Apple Silicon, or
`windows/eagler-patcher-windows-x86_64.cmd` on supported Windows 10/11 x64.
Each installs verified Java 17,
Java 25, and Node/npm inside the package. Read each platform README for its
exact limits. macOS and Windows still need native-host acceptance.

The Linux bootstrap supports x86_64 on glibc. Run `bootstrap/launch-gui-linux-x86_64.sh` from the package. It expects the GUI JAR in the parent application directory, installs the toolchain there, then starts the GUI with local Java 17. It does not modify `PATH`, install packages, or write to system directories. Run it as a normal user, without `sudo`.

The bootstrap downloads current Eclipse Temurin JDK releases for Java 17 and Java 25 from the Eclipse Adoptium API. It compares each API SHA-256 with the release's `.sha256.txt` sidecar, then verifies the archive before extraction. It selects the current Node.js 24 LTS Linux x64 archive from `nodejs.org/dist/index.json` and checks it against that release's `SHASUMS256.txt`. Downloads must use HTTPS. The bootstrap extracts verified archives under `.toolchain/` and writes `toolchain.properties` after all four tools pass local version and launch checks.

`toolchain.properties` is a UTF-8 Java properties file. The GUI reads `java17`, `java25`, `node`, and `npm`; `npm` names the bundled `npm-cli.js`. Archive versions and SHA-256 values are recorded alongside those paths. A later run reuses the app-local toolchain when its manifest and executables still validate. Vendor updates may change which exact version a fresh install selects. Concurrent launches share `.toolchain/.bootstrap.lock` so only one installer publishes a toolchain at a time.

The bootstrap requires `curl`, `tar`, `sha256sum`, `flock`, `getconf`, and standard Linux utilities. It rejects musl Linux and architectures other than x86_64. Windows and macOS are explicitly unsupported by this bootstrap; the scripts make no changes there. The normal GUI JAR can still be launched manually where a compatible Java runtime is already installed.

This installs Java and Node/npm only. It does not download or redistribute the official Minecraft 26.2 JAR, Mojang assets, sound/media inputs, Vineflower, source patch, project skeleton, or resource overlay. Those inputs still need to meet their authentication and provenance requirements. Java and Node binaries come from their vendors. Project dependencies are installed later through the patcher's `npm ci --ignore-scripts` flow.

For a focused offline installer self-test, run `./test-bootstrap.sh` from this directory. It uses mocked vendor responses and archives, checks checksum rejection and idempotent discovery, and does not download or install real toolchains.

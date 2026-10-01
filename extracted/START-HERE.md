# Eaglercraft 26.2 u1 patcher setup

This setup JAR contains the maintainer-authorized Normal patcher package and
its pinned build inputs. It extracts the package into a directory you choose;
the included notices and integrity manifest must stay with that directory.

The official Minecraft 26.2 client JAR is intentionally not included. In the
GUI, choose the exact official client JAR that you are authorized to use. It
may remain in its existing folder. The package contains no private signing
keys, credentials, toolchain downloads, or setup logs.

1. Run the setup JAR with Java 17 or newer.
2. Choose an installation parent folder. The setup creates
   `eaglercraft-26.2-patcher` and verifies every packaged byte.
3. Use the desktop GUI to choose the official client JAR, project folder, and
   output. The bundled Normal inputs are discovered automatically.

The GUI can create a source project, Standalone HTML, or a local Isolated Web
App. Read `GUI.md` and `PORTABLE.md` for the platform launchers, resource
workflow, and build limits. The release package preserves all third-party
license and notice files; see `RELEASE-NOTICES.md` before redistributing or
modifying the package.


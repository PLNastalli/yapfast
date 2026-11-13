# Official Discord Go Live through WireSock (Windows)

Yapfast already implements Discord Go Live signalling and media streaming.
In regions where Discord withholds video or Go Live from a session, one
possible network-side workaround is to connect the **whole Yapfast process**
through an external WireGuard exit before opening Discord's gateway.
This still uses Discord's **official** Go Live and stream service, not an
alternative video service.

The optional launcher in [scripts/launch-golive-wiresock.ps1](../../scripts/launch-golive-wiresock.ps1)
does this on Windows. It was designed with the 2026 Brazilian Go Live
restrictions in mind, but is **not a guaranteed workaround**. Discord can
change how it determines eligibility and can reject streams even with a
working VPN. Check Discord's terms and applicable rules before using it.

## Prerequisites

- Windows 10 or 11 with Yapfast installed, or a local build of yapfast.exe.
- [WireSock Secure Connect](https://wiresock.net/) CLI installed with its
  Windows driver. The executable is named wiresock-client.exe.
- Your **own WireGuard .conf** from a VPN provider or your own server with
  egress outside the restricted region. WireSock does not provide VPN servers.
  The profile must have one [Peer] with AllowedIPs including 0.0.0.0/0.
- Quit Yapfast and any existing WireSock client/service before launching.

**Do not share your WireGuard .conf**: it contains a private key.

## Usage

From the repository directory in PowerShell:

    # Validate profile and executable paths without changing the network:
    .\scripts\launch-golive-wiresock.ps1 -WireGuardConfig 'C:\VPN\profile.conf' -CheckOnly

    # Start WireSock, then Yapfast; keep the terminal open:
    .\scripts\launch-golive-wiresock.ps1 -WireGuardConfig 'C:\VPN\profile.conf'

The script searches for Yapfast in the default installation directory
(%LOCALAPPDATA%\Programs\Yapfast) or a Cargo debug/release build. If
either executable is elsewhere, pass the explicit paths:

    .\scripts\launch-golive-wiresock.ps1 -WireGuardConfig 'C:\VPN\profile.conf' -YapfastExe 'D:\Apps\Yapfast\yapfast.exe' -WireSockExe 'C:\Program Files\WireSock VPN Client\wiresock-client.exe'

WireSock starts first. Yapfast is then launched with a fresh gateway
connection. Join your voice channel after the new client starts and use
Yapfast's normal Go Live button.

The launcher runs the WireSock Secure Connect CLI (wiresock-client.exe
run -config), **not** wiresock-connect-cli, which has a different syntax.

## What changes

- The generated profile uses WireSock's #@ws:AllowedApps filter for the
  **full path of yapfast.exe**. Yapfast runs its --stream-worker as the
  same executable, so both main app and capture/media worker are routed.
- The entire process is routed, including gateway, authentication, voice
  signalling, WebSocket and encrypted RTP/UDP video. A gateway-only
  SOCKS proxy is not sufficient here.
- Games, browsers and other unrelated programs use their normal connection.
- The launcher drops the DNS setting from its temporary WireGuard profile
  to avoid changing the Windows-wide DNS resolver. Some VPN endpoints may
  require different DNS configuration and can fail with this choice.
- Network lock is disabled to avoid changing machine-wide connectivity.
  The launcher watches the WireSock process and closes the Yapfast main
  process if it dies, but **this is not a full fail-closed guarantee**.

## Privacy and failure handling

The launcher refuses to start if Yapfast is already running or a WireSock
CLI process or known WireSock service is active. It never stops another
session, downloads code, handles Proton credentials or touches Discord tokens.

The modified WireGuard profile is temporarily stored under
%LOCALAPPDATA%\Yapfast\GoLiveTunnel with a restrictive ACL (user and
SYSTEM) and removed on normal exit. A sudden shutdown can leave a
wiresock-*.conf behind. Delete stale profiles in that directory because
they contain WireGuard private keys.

If WireSock exits during startup, verify that WireSock and its driver are
installed, the profile works independently and Windows permissions allow
the client to run. A running process **does not prove** the VPN has
handshaken or that the exit is outside Brazil. Verify the actual route
before relying on it.

**Testing status:** Config generation and script syntax can be checked
without credentials; an end-to-end Discord Go Live test from Brazil has
not been performed. The Discord server ultimately decides whether the
official stream is available.

## References

- [WireSock per-app split tunnelling](https://wiresock.net/documentation/guide/route-one-app-through-wireguard-windows.html)
- [WireSock CLI reference](https://wiresock.net/documentation/wiresock-secure-connect/command-line-interface.html)
- [WireSock profile directives](https://wiresock.net/documentation/wiresock-secure-connect/advanced-parameters.html)

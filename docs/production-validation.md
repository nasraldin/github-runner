# Production Validation Report

Validation host:

- Host OS: macOS ARM64
- Docker engine: Linux ARM64
- Windows VM: Windows 11 ARM64 on Parallels Desktop
- Repository under test: configured in `runners.config.json`

## Artifact Validation

All configured runner package URLs were downloaded and verified against their configured SHA-256 hashes.

| Package                 | Result |
| ----------------------- | ------ |
| `linux-x64-2.335.1`     | PASS   |
| `linux-arm64-2.335.1`   | PASS   |
| `macos-arm64-2.335.1`   | PASS   |
| `windows-x64-2.335.1`   | PASS   |
| `windows-arm64-2.335.1` | PASS   |

## Live Registration Validation

| Pool                 | Host Used                                           | Result                                                                                                                                                     |
| -------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Linux ARM64 Docker   | macOS ARM64 Docker Desktop, Linux ARM64 engine      | PASS: 3 runners registered online and deregistered cleanly                                                                                                 |
| macOS ARM64 native   | macOS ARM64 host                                    | PASS: native runner registered online and deregistered cleanly                                                                                             |
| Linux x64 Docker     | macOS ARM64 Docker Desktop with amd64 emulation     | NOT PRODUCTION-VALIDATED: GitHub runner authenticated, then crashed in the runner/.NET registration path under QEMU                                        |
| Windows ARM64 native | Windows 11 ARM64 on Parallels Desktop               | PASS: native runner registered online and deregistered cleanly; GitHub marks Windows ARM64 runners pre-release                                             |
| Windows x64 native   | Windows 11 ARM64 on Parallels Desktop x64 emulation | PASS: x64 runner package registered online and deregistered cleanly under Windows ARM emulation; use a Windows x64 host for production-equivalent sign-off |
| Windows x64 Docker   | Not available on this host                          | REQUIRES Windows Docker host and Windows runner image                                                                                                      |
| Windows ARM64 Docker | Not available on this host                          | REQUIRES Windows Docker host and Windows ARM64 runner image                                                                                                |

## Important Conclusion

The ARM MacBook is valid for:

- Linux ARM64 Docker runner pools
- macOS ARM64 native runner pools
- Windows ARM64 native runner pools through the Windows ARM VM
- Windows x64 native runner package compatibility through Windows ARM x64 emulation

It is not a production-equivalent validation host for:

- Linux x64 Docker runner pools
- Windows x64 native runner pools on real x64 hardware
- Windows Docker runner pools

For full production sign-off, run the same manager on:

- A Linux x64 server for `linux-x64-docker`
- A Windows x64 machine or VM for hardware-equivalent `windows-x64-native`
- A Windows Docker host before enabling Windows Docker pools

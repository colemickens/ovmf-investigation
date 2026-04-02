ovmf-investigation
------------------

see: https://github.com/NixOS/nixpkgs/issues/485220

- `nix run` runs a qemu script that executes qemu with ovmf
- partially vibe-coded quick smoke test of qemu+ovmf
- I don't have easy access to `{x86_64,aarch64}-linux` with `kvm` but some test
  coverage and anecdotal reports indicate it's an `hvf` thing... I think.

note:
- `nixpkgs` is used for qemu and misc
- `nixpkgs-ovmf` is used for the ovmf/aavmf firmware

- see `flake.nix` for notes on combos that do/don't work

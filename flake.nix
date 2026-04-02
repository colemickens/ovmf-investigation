{
  description = "Cross-platform QEMU systemd-boot smoke test";

  inputs = {
    # # combo 1 => nix run => 1 (FAIL with hvf)
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-ovmf.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    # # combo 2 => nix run => 0 (PASS with hvf)
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # nixpkgs-ovmf.url = "github:NixOS/nixpkgs/nixos-25.11";

    # # combo 1 => nix run => 0 (PASS with hvf)
    # nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # nixpkgs-ovmf.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = inputs:
    let
      lib = inputs.nixpkgs.lib;
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs supportedSystems (system: f system);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          firmwarePkgs =
            if system == "aarch64-darwin"
            then inputs.nixpkgs-ovmf.legacyPackages.aarch64-linux
            else inputs.nixpkgs-ovmf.legacyPackages.${system};

          guestArch = if system == "x86_64-linux" then "x86_64" else "aarch64";
          qemuBin = if guestArch == "x86_64" then "qemu-system-x86_64" else "qemu-system-aarch64";

          systemdBootEfi = if guestArch == "x86_64"
            then "${firmwarePkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi"
            else "${firmwarePkgs.systemd}/lib/systemd/boot/efi/systemd-bootaa64.efi";
          bootFallbackName = if guestArch == "x86_64" then "BOOTX64.EFI" else "BOOTAA64.EFI";

          # firmwarePackage = if guestArch == "x86_64" then firmwarePkgs.OVMF else firmwarePkgs.AAVMF;
          firmwarePackage = firmwarePkgs.OVMF;
          firmwareDir = if firmwarePackage ? fd then firmwarePackage.fd else firmwarePackage;

          accel = if lib.hasSuffix "-darwin" system then "hvf" else "kvm";
          # accel = "";

          checkSystemdBoot = pkgs.writeShellApplication {
            name = "check-systemd-boot";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.qemu
            ];
            excludeShellChecks = [ "SC2329" "SC2050" "SC2054" "SC2317" ];
            text = ''
              set -x
              set -euo pipefail

              timeout_seconds="''${TIMEOUT_SECONDS:-180}"
              workdir="$(mktemp -d)"
              echo "workdir = $workdir  ============================="
              efi_dir="$workdir/efi"
              log_file="$workdir/qemu.log"
              vars_file="$workdir/vars.fd"

              cleanup() {
                if [[ -n "''${qemu_pid:-}" ]] && kill -0 "$qemu_pid" 2>/dev/null; then
                  kill "$qemu_pid" 2>/dev/null || true
                  wait "$qemu_pid" 2>/dev/null || true
                fi
                # rm -rf "$workdir"
              }
              trap cleanup EXIT

              firmware_dir="${firmwareDir}"
              firmware_code="$(find "$firmware_dir" -type f -name '*.fd' ! -iname '*VARS*' | sort | head -n1 || true)"
              firmware_vars_template="$(find "$firmware_dir" -type f -name '*VARS*.fd' | sort | head -n1 || true)"

              if [[ -z "$firmware_code" || -z "$firmware_vars_template" ]]; then
                echo "Could not locate firmware CODE/VARS files under: $firmware_dir" >&2
                exit 1
              fi

              mkdir -p "$efi_dir/EFI/BOOT" "$efi_dir/EFI/systemd" "$efi_dir/loader/entries"
              cp "${systemdBootEfi}" "$efi_dir/EFI/systemd/$(basename "${systemdBootEfi}")"
              cp "${systemdBootEfi}" "$efi_dir/EFI/BOOT/${bootFallbackName}"

              cat > "$efi_dir/loader/loader.conf" <<'EOF'
              timeout 5
              default @saved
              editor no
              console-mode keep
              EOF

              cp "$firmware_vars_template" "$vars_file"
              chmod +w "''${vars_file}"
              : > "$log_file"

              if [[ "${accel}" == "kvm" && ! -e /dev/kvm ]]; then
                echo "Requested KVM acceleration but /dev/kvm is not available." >&2
                exit 1
              fi

              qemu_cmd=(
                ${pkgs.qemu}/bin/${qemuBin}
                -m 1024
                -nographic
                -serial stdio
                -monitor none
                -no-reboot
                -drive if=pflash,format=raw,readonly=on,file="$firmware_code"
                -drive if=pflash,format=raw,file="$vars_file"
                -drive if=virtio,format=raw,file="fat:rw:$efi_dir"
              )

              if [[ "${guestArch}" == "x86_64" ]]; then
                qemu_cmd+=( -machine q35 )
              else
                qemu_cmd+=( -machine virt )
              fi

              if [[ "${accel}" != "" ]]; then
                qemu_cmd+=( -accel "${accel}" -cpu host)
              else 
                qemu_cmd+=( -M virt)
              fi

              sleep 4

              "''${qemu_cmd[@]}" >"$log_file" 2>&1 &
              qemu_pid=$!

              deadline=$((SECONDS + timeout_seconds))
              found=0

              while true; do
                if grep -qi 'Boot in 5 s.' "$log_file"; then
                  found=1
                  break
                fi

                if ! kill -0 "$qemu_pid" 2>/dev/null; then
                  break
                fi

                if (( SECONDS >= deadline )); then
                  break
                fi

                sleep 1
              done

              if (( found == 1 )); then
                echo "Detected systemd-boot startup in QEMU output."
                kill "$qemu_pid" 2>/dev/null || true
                wait "$qemu_pid" 2>/dev/null || true
                exit 0
              fi

              if kill -0 "$qemu_pid" 2>/dev/null; then
                echo "Timed out after ''${timeout_seconds}s waiting for systemd-boot." >&2
                kill "$qemu_pid" 2>/dev/null || true
                wait "$qemu_pid" 2>/dev/null || true
              else
                wait "$qemu_pid" || true
                echo "QEMU exited before systemd-boot was detected." >&2
              fi

              echo "--- QEMU Log ---" >&2
              echo "$log_file" >&2
              exit 1
            '';
          };
        in
        {
          default = checkSystemdBoot;
          check-systemd-boot = checkSystemdBoot;
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${inputs.self.packages.${system}.check-systemd-boot}/bin/check-systemd-boot";
        };
      });
    };
}

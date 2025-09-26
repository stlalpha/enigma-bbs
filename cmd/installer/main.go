package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	_ "embed"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var (
	version   = "dev"
	buildDate = "unknown"
	gitCommit = "unknown"
)

//go:embed release-data.tar.gz
var releaseDataTarGz []byte

const (
	colorReset  = "\033[0m"
	colorBold   = "\033[1m"
	colorCyan   = "\033[36m"
	colorGreen  = "\033[32m"
	colorYellow = "\033[33m"
	colorBlue   = "\033[34m"
	colorRed    = "\033[31m"
)

type installer struct {
	platform   string
	arch       string
	installDir string
}

func main() {
	inst := &installer{platform: runtime.GOOS, arch: runtime.GOARCH}

	inst.banner()
	inst.checkSystem()
	inst.promptDestination()
	inst.confirmInstall()
	if err := inst.extractPayload(); err != nil {
		inst.fatal("Extraction failed: %v", err)
	}
	if err := inst.createLaunchers(); err != nil {
		inst.warn("Failed to create launcher scripts: %v", err)
	}
	if err := inst.generateConfig(); err != nil {
		inst.warn("Configuration bootstrap skipped: %v", err)
	}
	inst.complete()
}

func (i *installer) banner() {
	fmt.Print(colorCyan + colorBold)
	fmt.Println("╔══════════════════════════════════════════════════════════════════╗")
	fmt.Printf("║                 ENiGMA½ Self-Contained Installer %-12s║\n", version)
	fmt.Println("║                                                                  ║")
	fmt.Printf("║           Platform detected: %-12s Arch: %-14s║\n", i.platform, i.arch)
	fmt.Println("╚══════════════════════════════════════════════════════════════════╝")
	fmt.Print(colorReset + "\n")
	time.Sleep(600 * time.Millisecond)
}

func (i *installer) checkSystem() {
	fmt.Printf("%s[STEP]%s Validating host prerequisites...\n", colorBlue+colorBold, colorReset)
	if _, err := exec.LookPath("tar"); err != nil {
		i.fatal("Required utility 'tar' not found in PATH")
	}
	if _, err := exec.LookPath("gzip"); err != nil {
		i.fatal("Required utility 'gzip' not found in PATH")
	}
	fmt.Printf("%s✓%s Core utilities available\n\n", colorGreen, colorReset)
}

func (i *installer) promptDestination() {
	defaultDir := defaultInstallDir(i.platform)
	reader := bufio.NewReader(os.Stdin)

	for {
		fmt.Printf("Select installation directory [%s]: ", defaultDir)
		input, err := reader.ReadString('\n')
		if err != nil {
			i.fatal("Failed reading input: %v", err)
		}
		input = strings.TrimSpace(input)
		if input == "" {
			input = defaultDir
		}
		resolved, err := filepath.Abs(expandPath(input))
		if err != nil {
			fmt.Printf("%sInvalid path:%s %v\n", colorRed, colorReset, err)
			continue
		}
		i.installDir = resolved
		break
	}
	fmt.Printf("Installing to %s%s%s\n\n", colorGreen, i.installDir, colorReset)
}

func (i *installer) confirmInstall() {
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Printf("Proceed with installation? [Y/n]: ")
		input, err := reader.ReadString('\n')
		if err != nil {
			i.fatal("Failed reading input: %v", err)
		}
		input = strings.TrimSpace(strings.ToLower(input))
		if input == "" || input == "y" || input == "yes" {
			fmt.Println()
			return
		}
		if input == "n" || input == "no" {
			fmt.Println("Installation cancelled.")
			os.Exit(0)
		}
		fmt.Println("Please answer 'y' or 'n'.")
	}
}

func (i *installer) extractPayload() error {
	fmt.Printf("%s[STEP]%s Extracting packaged runtime...\n", colorBlue+colorBold, colorReset)

	if len(releaseDataTarGz) == 0 {
		return errors.New("embedded payload missing")
	}

	if err := os.MkdirAll(i.installDir, 0o755); err != nil {
		return err
	}

	gzReader, err := gzip.NewReader(bytes.NewReader(releaseDataTarGz))
	if err != nil {
		return err
	}
	defer gzReader.Close()

	tarReader := tar.NewReader(gzReader)

	for {
		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		targetPath := filepath.Join(i.installDir, header.Name)
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, os.FileMode(header.Mode)); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := writeFile(targetPath, tarReader, os.FileMode(header.Mode)); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
				return err
			}
			if err := os.Symlink(header.Linkname, targetPath); err != nil {
				return err
			}
		default:
			// skip other types
		}
	}

	fmt.Printf("%s✓%s Files extracted\n\n", colorGreen, colorReset)
	return nil
}

func (i *installer) createLaunchers() error {
	fmt.Printf("%s[STEP]%s Writing helper scripts...\n", colorBlue+colorBold, colorReset)
	runtimeDir := filepath.Join(i.installDir, "runtime")

	if err := os.MkdirAll(filepath.Join(i.installDir, "bin"), 0o755); err != nil {
		return err
	}

	if _, err := findRuntimeNode(runtimeDir); err != nil {
		return err
	}

	switch i.platform {
	case "windows":
		script := "@echo off\r\n" +
			"setlocal\r\n" +
			"set ENIGMA_HOME=%~dp0..\r\n" +
			"set PATH=%ENIGMA_HOME%\\runtime;%ENIGMA_HOME%\\runtime\\bin;%PATH%\r\n" +
			"cd /d %ENIGMA_HOME%\r\n" +
			"node main.js %*\r\n"
		return os.WriteFile(filepath.Join(i.installDir, "bin", "start-enigma.bat"), []byte(script), 0o755)
	default:
		script := fmt.Sprintf("#!/bin/bash\nset -e\nENIGMA_HOME=\"$(cd \"$(dirname $0)/..\" && pwd)\"\nexport PATH=\"$ENIGMA_HOME/runtime/bin:$PATH\"\ncd \"$ENIGMA_HOME\"\nexec node main.js \"$@\"\n")
		if err := os.WriteFile(filepath.Join(i.installDir, "bin", "start-enigma.sh"), []byte(script), 0o755); err != nil {
			return err
		}
		if err := os.Chmod(filepath.Join(i.installDir, "bin", "start-enigma.sh"), 0o755); err != nil {
			return err
		}
	}

	fmt.Printf("%s✓%s Launch scripts created\n\n", colorGreen, colorReset)
	return nil
}

func (i *installer) generateConfig() error {
	fmt.Printf("%s[STEP]%s Preparing initial configuration...\n", colorBlue+colorBold, colorReset)
	nodePath, err := findRuntimeNode(filepath.Join(i.installDir, "runtime"))
	if err != nil {
		return fmt.Errorf("node runtime missing: %w", err)
	}

	script := filepath.Join(i.installDir, "scripts", "postinstall.js")
	if _, err := os.Stat(script); err != nil {
		// silently skip; bundle may not include generator yet
		return fmt.Errorf("postinstall script not present")
	}

	cmd := exec.Command(nodePath, script, "--install-dir", i.installDir)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("postinstall failed: %w", err)
	}

	fmt.Printf("%s✓%s Configuration seeded\n\n", colorGreen, colorReset)
	return nil
}

func (i *installer) complete() {
	fmt.Printf("%sInstallation complete!%s\n", colorGreen+colorBold, colorReset)
	fmt.Printf("Next steps:\n  %s\n", filepath.Join(i.installDir, launcherHint(i.platform)))
	fmt.Println("Review config files under config/ and adjust ports, name, and access controls.")
}

func (i *installer) warn(format string, args ...any) {
	fmt.Printf(colorYellow+"Warning: "+colorReset+format+"\n", args...)
}

func (i *installer) fatal(format string, args ...any) {
	fmt.Printf(colorRed+"Error: "+colorReset+format+"\n", args...)
	os.Exit(1)
}

func writeFile(path string, reader io.Reader, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	defer file.Close()

	if _, err := io.Copy(file, reader); err != nil {
		return err
	}

	return nil
}

func defaultInstallDir(platform string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}

	switch platform {
	case "windows":
		return filepath.Join(home, "EnigmaBBS")
	default:
		return filepath.Join(home, "enigma-bbs")
	}
}

func expandPath(path string) string {
	if strings.HasPrefix(path, "~") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~"))
		}
	}
	return path
}

func launcherHint(platform string) string {
	if platform == "windows" {
		return "bin\\start-enigma.bat"
	}
	return "bin/start-enigma.sh"
}

func findRuntimeNode(runtimeDir string) (string, error) {
	candidates := []string{
		filepath.Join(runtimeDir, "bin", "node"),
		filepath.Join(runtimeDir, "node"),
		filepath.Join(runtimeDir, "node.exe"),
		filepath.Join(runtimeDir, "bin", "node.exe"),
	}

	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}

	return "", errors.New("node executable not found in runtime")
}

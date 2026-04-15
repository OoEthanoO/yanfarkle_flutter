package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func main() {
	// 1. Get version from pubspec.yaml
	version, err := getVersion()
	if err != nil {
		fmt.Printf("Error reading version: %v\n", err)
		os.Exit(1)
	}

	appName := "YanFarkle"
	appBundle := appName + ".app"
	sourceAppPath := filepath.Join("build", "macos", "Build", "Products", "Release", appBundle)
	dmgName := fmt.Sprintf("YanFarkle_%s.dmg", version)
	stagingDir := "dmg_staging"

	fmt.Printf("Packaging %s into %s...\n", appBundle, dmgName)

	// 2. Check if app exists
	if _, err := os.Stat(sourceAppPath); os.IsNotExist(err) {
		fmt.Printf("App bundle not found at %s. Please run 'flutter build macos' first.\n", sourceAppPath)
		os.Exit(1)
	}

	// 3. Prepare staging directory
	os.RemoveAll(stagingDir)
	err = os.MkdirAll(stagingDir, 0755)
	if err != nil {
		fmt.Printf("Error creating staging dir: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(stagingDir)

	// 4. Copy .app to staging (using cp -R to preserve permissions/symlinks)
	fmt.Println("Copying app bundle...")
	cmd := exec.Command("cp", "-R", sourceAppPath, stagingDir)
	if err := cmd.Run(); err != nil {
		fmt.Printf("Error copying app: %v\n", err)
		os.Exit(1)
	}

	// 5. Create symlink to Applications
	fmt.Println("Creating Applications symlink...")
	err = os.Symlink("/Applications", filepath.Join(stagingDir, "Applications"))
	if err != nil {
		fmt.Printf("Error creating symlink: %v\n", err)
		os.Exit(1)
	}

	// 6. Create DMG using hdiutil
	fmt.Println("Creating DMG...")
	dmgPath := filepath.Join("build", "macos", dmgName)
	// Ensure build/macos directory exists
	os.MkdirAll(filepath.Join("build", "macos"), 0755)

	cmd = exec.Command("hdiutil", "create",
		"-volname", "YanFarkle",
		"-srcfolder", stagingDir,
		"-ov",
		"-format", "UDZO",
		dmgPath)

	output, err := cmd.CombinedOutput()
	if err != nil {
		fmt.Printf("Error creating DMG: %v\nOutput: %s\n", err, string(output))
		os.Exit(1)
	}

	fmt.Printf("\nSuccess! DMG created at: %s\n", dmgPath)
}

func getVersion() (string, error) {
	data, err := os.ReadFile("pubspec.yaml")
	if err != nil {
		return "", err
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		if strings.HasPrefix(line, "version:") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "version:"))
			// Split by + to remove build number
			parts := strings.Split(v, "+")
			return parts[0], nil
		}
	}

	return "1.0.0", nil // Fallback
}

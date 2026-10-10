app := "build/ScreenShotter.app"

# Build build/ScreenShotter.app
app:
    ./scripts/build-app.sh

# Build and launch
run: app
    -pkill -x 'Screen[Ss]hotter'
    for attempt in $(seq 1 50); do if ! pgrep -x 'Screen[Ss]hotter' >/dev/null; then break; fi; sleep 0.1; done
    if pgrep -x 'Screen[Ss]hotter' >/dev/null; then echo "ScreenShotter did not quit; close it and retry." >&2; exit 1; fi
    open {{app}}

# Run the test suite (extra args go to swift test, e.g. `just test --filter Crop`)
test *args:
    swift test {{args}}

# Copy to /Applications and launch
install: app
    -pkill -x 'Screen[Ss]hotter'
    for attempt in $(seq 1 50); do if ! pgrep -x 'Screen[Ss]hotter' >/dev/null; then break; fi; sleep 0.1; done
    if pgrep -x 'Screen[Ss]hotter' >/dev/null; then echo "ScreenShotter did not quit; close it and retry." >&2; exit 1; fi
    rm -rf /Applications/Screenshotter.app /Applications/ScreenShotter.app
    cp -R {{app}} /Applications/
    open /Applications/ScreenShotter.app

# Regenerate Resources/AppIcon.png from CaptureGlyph.swift
icon:
    mkdir -p build
    swiftc Sources/Screenshotter/CaptureGlyph.swift scripts/generate-icon.swift -o build/generate-icon
    build/generate-icon

clean:
    rm -rf .build build

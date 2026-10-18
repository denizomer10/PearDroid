APP := build/PearDroid.app
BIN := $(APP)/Contents/MacOS/PearDroid

.PHONY: all app run open clean

all: app

## Build the app bundle (shaders + Swift + resources)
app:
	@bash scripts/build.sh

## Build and run in the foreground so renderer logs are visible
run: app
	$(BIN)

## Build and launch through LaunchServices like a normal app
open: app
	open $(APP)

clean:
	rm -rf build

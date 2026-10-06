.PHONY: build run install test clean protection-test protection-hold simulate

build:
	./scripts/build.sh

run: build
	open build/VoicePrompter.app

test:
	swift test

# Copies the app to /Applications so Spotlight, Launchpad and "Open at login" can find it.
install: build
	rm -rf /Applications/VoicePrompter.app
	cp -R build/VoicePrompter.app /Applications/
	open /Applications/VoicePrompter.app

# Try the overlay without a microphone.
simulate: build
	open build/VoicePrompter.app --args --engine simulated --autostart

ProtectionTest/prottest: ProtectionTest/main.swift
	swiftc -O -target $(shell uname -m)-apple-macosx14.0 ProtectionTest/main.swift -o ProtectionTest/prottest

# Checks sharingType=.none against every capture API (needs Screen Recording permission for your terminal).
protection-test: ProtectionTest/prottest
	./ProtectionTest/prottest

# Shows protected (magenta) + control (green) squares for 60 s so you can test Zoom/Meet/QuickTime by hand.
protection-hold: ProtectionTest/prottest
	./ProtectionTest/prottest hold 60

clean:
	rm -rf .build build ProtectionTest/prottest

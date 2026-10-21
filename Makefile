CC := clang
MIN_VER := 15.0
CFLAGS := -arch arm64 -mmacosx-version-min=$(MIN_VER) -std=c17 -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -fPIC -fvisibility=hidden -MMD -MP -Isrc -Ivendor -Ivendor/dobby/include
PATCH_SRCS := $(wildcard src/patch/*.c src/patch/*/*.c)
SRCS := $(filter-out src/stub_x86_64.c,$(wildcard src/*.c)) $(PATCH_SRCS) vendor/cJSON.c
OBJS := $(patsubst %.c,out/%.o,$(SRCS))
DOBBY := build/dobby
LIBS := $(DOBBY)/libdobby.a $(DOBBY)/builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a $(DOBBY)/builtin-plugin/SymbolResolver/libmacho_ctx_kit.a $(DOBBY)/builtin-plugin/SymbolResolver/libshared_cache_ctx_kit.a $(DOBBY)/external/osbase/libosbase.a $(DOBBY)/external/logging/liblogging.a

.PHONY: all manager test clean
all: out/onlinefix.dylib manager

manager: out/manager.stamp

PHOTON_SOURCE := $(or $(wildcard OnlineFixManager/Models/PhotonServers.local.swift),OnlineFixManager/Models/PhotonServers.swift)
MANAGER_SOURCES := $(filter-out OnlineFixManager/Tests/% OnlineFixManager/Models/PhotonServers%.swift,$(wildcard OnlineFixManager/*/*.swift)) $(PHOTON_SOURCE)
SWIFTFLAGS := -target arm64-apple-macos$(MIN_VER) -swift-version 6 -O -g -parse-as-library -module-cache-path out/swift-module-cache
SWIFTFLAGS += -import-objc-header src/patch/manager.h
MANAGER_PATCH_OBJS := out/src/patch/gamespecific/repo.o out/src/patch/gamespecific/terraria_server.o out/src/patch/gamespecific/pico_park_2.o out/src/patch/gamespecific/phasmophobia.o
PROFILES := $(wildcard signatures/macos.arm64/*.json)

out/7zip/7zz: scripts/fetch-7zip.sh
	bash scripts/fetch-7zip.sh

out/manager.stamp: Makefile $(MANAGER_SOURCES) OnlineFixManager/Info.plist out/onlinefix.dylib $(PROFILES) $(MANAGER_PATCH_OBJS) src/patch/manager.h out/7zip/7zz
	@mkdir -p out/OnlineFixManager.app/Contents/MacOS out/OnlineFixManager.app/Contents/Resources/runtime
	cp OnlineFixManager/Info.plist out/OnlineFixManager.app/Contents/Info.plist
	rm -f out/OnlineFixManager.app/Contents/Resources/runtime/*.json
	rm -f out/OnlineFixManager.app/Contents/Resources/runtime/pico_park_2_endpoint.py
	cp out/onlinefix.dylib $(PROFILES) out/OnlineFixManager.app/Contents/Resources/runtime/
	cp out/7zip/7zz out/OnlineFixManager.app/Contents/Resources/7zz
	cp out/7zip/License.txt out/OnlineFixManager.app/Contents/Resources/7zip-License.txt
	codesign --force --sign - out/OnlineFixManager.app/Contents/Resources/7zz
	xcrun swiftc $(SWIFTFLAGS) $(MANAGER_SOURCES) $(MANAGER_PATCH_OBJS) -o out/OnlineFixManager.app/Contents/MacOS/OnlineFixManager
	codesign --force --sign - out/OnlineFixManager.app
	@touch $@

vendor/dobby/include/dobby.h:
	bash scripts/fetch-dobby.sh

$(OBJS): | vendor/dobby/include/dobby.h

$(DOBBY)/libdobby.a: vendor/dobby/include/dobby.h
	cmake -S vendor/dobby -B $(DOBBY) -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=$(MIN_VER) -DDOBBY_DEBUG=OFF
	$(MAKE) -C $(DOBBY) -j4

out/%.o: %.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

out/onlinefix.arm64.dylib: $(OBJS) $(DOBBY)/libdobby.a
	$(CC) -arch arm64 -mmacosx-version-min=$(MIN_VER) -dynamiclib -Wl,-exported_symbols_list,exports.txt -install_name @rpath/onlinefix.dylib -o $@ $(OBJS) $(LIBS) -lc++ -framework CoreFoundation

out/onlinefix.x86_64.dylib: src/stub_x86_64.c
	@mkdir -p out
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) -dynamiclib -install_name @rpath/onlinefix.dylib -o $@ $<

out/onlinefix.dylib: out/onlinefix.arm64.dylib out/onlinefix.x86_64.dylib
	lipo -create $^ -output $@
	codesign -fs - $@

out/test_onlinefix: tests/test_onlinefix.c src/session.c src/onlinefix.c src/profile.c src/children.c src/config.c src/onlinefix.h src/ipc.h src/patch/patch.h src/patch/gamespecific/terraria_server.h $(PATCH_SRCS) vendor/cJSON.c vendor/cJSON.h $(PROFILES)
	@mkdir -p out
	$(CC) $(CFLAGS) tests/test_onlinefix.c src/session.c src/config.c $(PATCH_SRCS) vendor/cJSON.c -framework CoreFoundation -o $@

out/test_onlinefix: | vendor/dobby/include/dobby.h

out/test_manager: Makefile $(filter-out OnlineFixManager/Models/PhotonServers%.swift,$(wildcard OnlineFixManager/Tests/*.swift OnlineFixManager/Models/*.swift OnlineFixManager/Services/*.swift OnlineFixManager/Patches/*.swift)) $(PHOTON_SOURCE) $(MANAGER_PATCH_OBJS) src/patch/manager.h src/patch/gamespecific/terraria_server.h src/patch/gamespecific/pico_park_2.h src/patch/gamespecific/phasmophobia.h src/patch/gamespecific/repo.h
	@mkdir -p out
	xcrun swiftc $(SWIFTFLAGS) $(filter %.swift %.o,$^) -o $@

out/test_pico_patch: tests/test_pico_patch.c src/patch/gamespecific/pico_park_2.c src/patch/gamespecific/pico_park_2.h
	$(CC) $(CFLAGS) tests/test_pico_patch.c -framework CoreFoundation -o $@

out/test_phasmophobia_patch: tests/test_phasmophobia_patch.c src/patch/gamespecific/phasmophobia.c src/patch/gamespecific/phasmophobia.h
	@mkdir -p out
	$(CC) $(CFLAGS) tests/test_phasmophobia_patch.c -o $@

out/test_repo_patch: tests/test_repo_patch.c src/patch/gamespecific/repo.c src/patch/gamespecific/repo.h
	@mkdir -p out
	$(CC) $(CFLAGS) tests/test_repo_patch.c -o $@

test: out/test_onlinefix out/test_manager out/test_pico_patch out/test_phasmophobia_patch out/test_repo_patch out/manager.stamp
	./out/test_manager "$(CURDIR)/out/OnlineFixManager.app/Contents/Resources/runtime" "$(CURDIR)/out/test-manager-config.json"
	ONLINEFIX_TEST_CONFIG="$(CURDIR)/out/test-manager-config.json" ./out/test_onlinefix
	bash -n scripts/launch.sh
	bash tests/test_fetch_dobby.sh
	python3 tests/test_configure_photon.py
	./out/test_pico_patch
	./out/test_phasmophobia_patch
	./out/test_repo_patch

clean:
	rm -rf out build

-include $(OBJS:.o=.d)

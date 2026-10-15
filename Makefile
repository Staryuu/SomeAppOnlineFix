CC := clang
MIN_VER := 15.0
CFLAGS := -arch arm64 -mmacosx-version-min=$(MIN_VER) -std=c17 -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations -fPIC -fvisibility=hidden -MMD -MP -Isrc -Ivendor -Ivendor/dobby/include
PATCH_SRCS := $(wildcard src/patch/*.c)
SRCS := $(filter-out src/stub_x86_64.c,$(wildcard src/*.c)) $(PATCH_SRCS) vendor/cJSON.c
OBJS := $(patsubst %.c,out/%.o,$(SRCS))
DOBBY := build/dobby
LIBS := $(DOBBY)/libdobby.a $(DOBBY)/builtin-plugin/SymbolResolver/libdobby_symbol_resolver.a $(DOBBY)/builtin-plugin/SymbolResolver/libmacho_ctx_kit.a $(DOBBY)/builtin-plugin/SymbolResolver/libshared_cache_ctx_kit.a $(DOBBY)/external/osbase/libosbase.a $(DOBBY)/external/logging/liblogging.a

.PHONY: all manager test clean
all: out/onlinefix.dylib manager

manager: out/manager.stamp

MANAGER_SOURCES := $(filter-out OnlineFixManager/Tests.swift,$(wildcard OnlineFixManager/*.swift))
SWIFTFLAGS := -target arm64-apple-macos$(MIN_VER) -swift-version 6 -O -g -parse-as-library -module-cache-path out/swift-module-cache
SWIFTFLAGS += -import-objc-header src/patch/terraria_server.h
TERRARIA_PATCH_OBJ := out/src/patch/terraria_server.o
PROFILES := $(wildcard signatures/macos.arm64/*.json)

out/manager.stamp: $(MANAGER_SOURCES) OnlineFixManager/Info.plist out/onlinefix.dylib $(PROFILES) $(TERRARIA_PATCH_OBJ)
	@mkdir -p out/OnlineFixManager.app/Contents/MacOS out/OnlineFixManager.app/Contents/Resources/runtime
	cp OnlineFixManager/Info.plist out/OnlineFixManager.app/Contents/Info.plist
	rm -f out/OnlineFixManager.app/Contents/Resources/runtime/*.json
	cp out/onlinefix.dylib $(PROFILES) out/OnlineFixManager.app/Contents/Resources/runtime/
	xcrun swiftc $(SWIFTFLAGS) $(MANAGER_SOURCES) $(TERRARIA_PATCH_OBJ) -o out/OnlineFixManager.app/Contents/MacOS/OnlineFixManager
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
	$(CC) -arch arm64 -mmacosx-version-min=$(MIN_VER) -dynamiclib -Wl,-exported_symbols_list,exports.txt -install_name @rpath/onlinefix.dylib -o $@ $(OBJS) $(LIBS) -lc++

out/onlinefix.x86_64.dylib: src/stub_x86_64.c
	@mkdir -p out
	$(CC) -arch x86_64 -mmacosx-version-min=$(MIN_VER) -dynamiclib -install_name @rpath/onlinefix.dylib -o $@ $<

out/onlinefix.dylib: out/onlinefix.arm64.dylib out/onlinefix.x86_64.dylib
	lipo -create $^ -output $@
	codesign -fs - $@

out/test_onlinefix: tests/test_onlinefix.c src/session.c src/onlinefix.c src/profile.c src/children.c src/config.c src/onlinefix.h src/ipc.h src/patch/patch.h src/patch/terraria_server.h $(PATCH_SRCS) vendor/cJSON.c vendor/cJSON.h $(PROFILES)
	@mkdir -p out
	$(CC) $(CFLAGS) tests/test_onlinefix.c src/session.c src/config.c $(PATCH_SRCS) vendor/cJSON.c -o $@

out/test_onlinefix: | vendor/dobby/include/dobby.h

out/test_manager: OnlineFixManager/Tests.swift OnlineFixManager/Models.swift OnlineFixManager/Installer.swift OnlineFixManager/SteamStore.swift OnlineFixManager/TerrariaServerPatch.swift $(TERRARIA_PATCH_OBJ) src/patch/terraria_server.h
	@mkdir -p out
	xcrun swiftc $(SWIFTFLAGS) $(filter %.swift %.o,$^) -o $@

test: out/test_onlinefix out/test_manager out/manager.stamp
	./out/test_manager "$(CURDIR)/out/OnlineFixManager.app/Contents/Resources/runtime" "$(CURDIR)/out/test-manager-config.json"
	ONLINEFIX_TEST_CONFIG="$(CURDIR)/out/test-manager-config.json" ./out/test_onlinefix
	bash -n scripts/launch.sh
	bash tests/test_fetch_dobby.sh

clean:
	rm -rf out build

-include $(OBJS:.o=.d)

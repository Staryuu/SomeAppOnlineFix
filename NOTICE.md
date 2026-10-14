OnlineFixMac's implementation in src/ is written for this project. MacSteam was
used as a behavioral and ABI reference, rather than copying its functions.

The ARM64 AOB signature data in signatures/ is adapted from local macSteam
revision df4df07b6b215c75e6e365dbdde6f28619b0e938. Its AGPL-3.0 license is
preserved in LICENSE. MacSteam credits BetterSteamTools for the OnlineFix approach.

Dobby is vendored from revision 5dfc8546954ce3b3198132ab13fddb89ee92cdd7;
see vendor/dobby/LICENSE. cJSON retains its license in vendor/cJSON.c and .h.

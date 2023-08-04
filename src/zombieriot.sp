/**
 * ====================
 *     Zombie Riot
 *   File: zombieriot.sp
 *   Author: Greyscale
 * ==================== 
 */

#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <clientprefs>

#undef REQUIRE_PLUGIN
#include <market>

#define VERSION "2.3.3"

#pragma newdecls required

bool csgo = false;

#include "zriot/zombieriot"
#include "zriot/global"
#include "zriot/cvars"
#include "zriot/translation"
#include "zriot/offsets"
#include "zriot/spawnprotect"
#include "zriot/volumecontrol"
#include "zriot/ambience"
#include "zriot/zombiedata"
#include "zriot/humandata"
#include "zriot/daydata"
#include "zriot/targeting"
#include "zriot/overlays"
#include "zriot/zombie"
#include "zriot/human"
#include "zriot/hud"
#include "zriot/sayhooks"
#include "zriot/teamcontrol"
#include "zriot/weaponrestrict"
#include "zriot/commands"
#include "zriot/event"

public Plugin myinfo =
{
    name = "Zombie Riot", 
    author = "Greyscale, Oylsister, Oz_Lin", 
    description = "Humans stick together to fight off zombie attacks", 
    version = VERSION, 
    url = "https://github.com/oylsister/sm-zombieriot-2"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateGlobals();
    
    return APLRes_Success;
}

public void OnPluginStart()
{
    if (GetEngineVersion() == Engine_CSS)
        csgo = false;

    else if (GetEngineVersion() == Engine_CSGO)
        csgo = true;

    else
        LogError("Warning: Zombie Riot only support CSS and CSGO!");

    LoadTranslations("common.phrases.txt");
    LoadTranslations("zombieriot.phrases.txt");
    
    // ======================================================================
    
    ZRiot_PrintToServer("Plugin loading");
    
    // ======================================================================
    
    ServerCommand("bot_kick");
    
    // ======================================================================
    
    HookEvents();
    HookChatCmds();
    CreateCvars();
    HookCvars();
    CreateCommands();
    HookCommands();
    FindOffsets();
    InitTeamControl();
    InitWeaponRestrict();
    HumanClassInit();
    VolumeControlInit();
    
    // ======================================================================
    
    trieDeaths = CreateTrie();
    
    // ======================================================================
    
    market = LibraryExists("market");
    
    // ======================================================================
    
    CreateConVar("gs_zombieriot_version", VERSION, "[ZRiot] Current version of this plugin");
    
    // ======================================================================
    
    ZRiot_PrintToServer("Plugin loaded");

    for(int x = 1; x <= MaxClients; x++)
    {
        if(AreClientCookiesCached(x))
        {
            OnClientCookiesCached(x);
        }
    }
}

public void OnPluginEnd()
{
    ZRiotEnd();
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "market"))
	{
		market = false;
	}
}
 
public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "market"))
	{
		market = true;
	}
}

public void OnMapStart()
{
    MapChangeCleanup();
    
    LoadModelData();
    LoadDownloadData();
    
    BuildPath(Path_SM, gMapConfig, sizeof(gMapConfig), "configs/zriot");
    
    LoadZombieData(true);
    LoadDayData(true);
    LoadHumanData(true);
    
    FindMapSky();
    
    CheckMapConfig();

    GetMapVoteConVars();
    g_bAlreadyVoted = false;
}

public void OnConfigsExecuted()
{
    UpdateTeams();
    
    LoadAmbienceData();
    
    char mapconfig[PLATFORM_MAX_PATH];
    
    GetCurrentMap(mapconfig, sizeof(mapconfig));
    Format(mapconfig, sizeof(mapconfig), "sourcemod/zombieriot/%s.cfg", mapconfig);
    
    char path[PLATFORM_MAX_PATH];
    Format(path, sizeof(path), "cfg/%s", mapconfig);
    
    if (FileExists(path))
    {
        ServerCommand("exec %s", mapconfig);
    }
}

public void OnClientPutInServer(int client)
{
    bool fakeclient = IsFakeClient(client);
    
    InitClientDeathCount(client);
    
    int deathcount = GetClientDeathCount(client);
    int deaths_before_zombie = GetDayDeathsBeforeZombie(gDay);
    
    bZombie[client] = !fakeclient ? ((deaths_before_zombie > 0) && (fakeclient || (deathcount >= deaths_before_zombie))) : true;
    
    bZVision[client] = !IsFakeClient(client);
    
    gZombieID[client] = -1;
    
    gTarget[client] = -1;
    RemoveTargeters(client);
    
    tRespawn[client] = INVALID_HANDLE;
    
    ClientHookUse(client);
    
    FindClientDXLevel(client);
}

public void OnClientDisconnect(int client)
{
    if (!IsPlayerHuman(client))
        return;
    
    int count;
    
    for (int x = 1; x <= MaxClients; x++)
    {
        if (!IsClientInGame(x) || !IsPlayerHuman(x) || GetClientTeam(x) <= CS_TEAM_SPECTATOR)
            continue;
        
        count++;
    }
    
    if (count <= 1 && tHUD != INVALID_HANDLE)
    {
        CS_TerminateRound(5.0, CSRoundEnd_TerroristWin, true);

        int score = CS_GetTeamScore(CS_TEAM_T);
        CS_SetTeamScore(CS_TEAM_T, score++);
    }
}

public void OnClientCookiesCached(int client)
{
    HumanClassOnCookiesCahced(client);
    VolumeOnCookiesCached(client);
}

void MapChangeCleanup()
{
    gDay = 0;
    
    ClearArray(restrictedWeapons);
    ClearTrie(trieDeaths);
    
    tAmbience = INVALID_HANDLE;
    tHUD = INVALID_HANDLE;
    tFreeze = INVALID_HANDLE;
}

void CheckMapConfig()
{
    char mapname[64];
    GetCurrentMap(mapname, sizeof(mapname));
    
    Format(gMapConfig, sizeof(gMapConfig), "%s/%s", gMapConfig, mapname);
    
    LoadZombieData(false);
    LoadDayData(false);
}

void ZRiotEnd()
{
    CS_TerminateRound(3.0, CSRoundEnd_GameStart, true);
    
    SetHostname(hostname);
    
    UnhookCvars();
    UnhookEvents();
    
    ServerCommand("bot_all_weapons");
    ServerCommand("bot_kick");
    
    for (int x = 1; x <= MaxClients; x++)
    {
        if (!IsClientInGame(x))
        {
            continue;
        }
        
        if (tRespawn[x] != INVALID_HANDLE)
        {
            CloseHandle(tRespawn[x]);
            tRespawn[x] = INVALID_HANDLE;
        }
    }
}

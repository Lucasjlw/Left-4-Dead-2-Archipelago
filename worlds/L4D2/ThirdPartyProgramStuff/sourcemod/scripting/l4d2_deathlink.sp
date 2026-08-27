#pragma semicolon 1
#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#pragma newdecls required

#define TEAM_SURVIVOR 2

// Path_SM already resolves to "<moddir>/addons/sourcemod" - these are relative to that
#define DL_REL_DIR  "data/archipelago"
#define DL_REL_DATA "data/archipelago/mod_data"
#define DL_IN_FILE  "data/archipelago/mod_data/deathlink_incoming.txt"
#define DL_OUT_FILE "data/archipelago/mod_data/deathlink_outgoing.txt"

ConVar g_cvEnabled;
bool g_bSuppressOutgoing = false;
Handle g_hPollTimer = null;

public Plugin myinfo =
{
	name = "L4D2 Archipelago DeathLink",
	author = "AP L4D2",
	description = "Bridges Left 4 Dead 2 player deaths with Archipelago DeathLink via file-drop IPC with the AP companion app",
	version = "1.0.0",
	url = ""
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("l4d2_deathlink_enabled", "1", "Enable DeathLink integration (1 = enabled, 0 = disabled)", FCVAR_NONE);
	AutoExecConfig(true, "l4d2_deathlink");

	RegAdminCmd("sm_deathlink_test", Cmd_TestDeathlink, ADMFLAG_ROOT, "Force-trigger an incoming DeathLink death for testing");

	EnsureDataDirs();

	g_hPollTimer = CreateTimer(0.25, Timer_PollIncoming, _, TIMER_REPEAT);
}

public void OnPluginEnd()
{
	if (g_hPollTimer != null)
	{
		KillTimer(g_hPollTimer);
		g_hPollTimer = null;
	}
}

void EnsureDataDirs()
{
	char path[PLATFORM_MAX_PATH];

	BuildPath(Path_SM, path, sizeof(path), DL_REL_DIR);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}

	BuildPath(Path_SM, path, sizeof(path), DL_REL_DATA);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
}

// ---------------------------------------------------------------------
// Outgoing: a real survivor death happened in-game -> tell the companion
// ---------------------------------------------------------------------

public void L4D_OnDeathDroppedWeapons(int client, int weapons[6])
{
	if (!g_cvEnabled.BoolValue)
		return;

	if (client <= 0 || client > MaxClients || !IsClientInGame(client))
		return;

	if (IsFakeClient(client))
		return;

	if (GetClientTeam(client) != TEAM_SURVIVOR)
		return;

	if (g_bSuppressOutgoing)
	{
		// This death was caused by an incoming DeathLink-forced suicide - don't echo it back out
		return;
	}

	char victimName[MAX_NAME_LENGTH];
	GetClientName(client, victimName, sizeof(victimName));

	WriteOutgoingDeath(victimName);
}

void WriteOutgoingDeath(const char[] victimName)
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), DL_OUT_FILE);

	File file = OpenFile(path, "w");
	if (file == null)
	{
		LogError("l4d2_deathlink: failed to open %s for writing", path);
		return;
	}

	file.WriteLine("%d|%s", GetTime(), victimName);
	file.Close();
}

// ---------------------------------------------------------------------
// Incoming: the companion signals a remote DeathLink death -> kill someone
// ---------------------------------------------------------------------

public Action Timer_PollIncoming(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
		return Plugin_Continue;

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), DL_IN_FILE);

	if (!FileExists(path))
		return Plugin_Continue;

	char line[256];
	File file = OpenFile(path, "r");
	if (file != null)
	{
		file.ReadLine(line, sizeof(line));
		file.Close();
	}

	// Delete immediately so we never process the same trigger twice
	DeleteFile(path);

	ApplyIncomingDeathLink();

	return Plugin_Continue;
}

void ApplyIncomingDeathLink()
{
	// Set the guard before killing anyone - the human survivor's own death
	// hook must not echo this incoming DeathLink back out as an outgoing one.
	g_bSuppressOutgoing = true;

	bool killedAny = false;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
		{
			killedAny = true;
			ForcePlayerSuicide(i);
		}
	}

	if (!killedAny)
	{
		g_bSuppressOutgoing = false;
		return;
	}

	// Clear the guard on a short delay rather than immediately - the death
	// hook may fire a frame later than this call returns.
	CreateTimer(0.5, Timer_ClearGuard);
}

public Action Timer_ClearGuard(Handle timer)
{
	g_bSuppressOutgoing = false;
	return Plugin_Stop;
}

public Action Cmd_TestDeathlink(int client, int args)
{
	ApplyIncomingDeathLink();
	ReplyToCommand(client, "[DeathLink] Triggered a test incoming death.");
	return Plugin_Handled;
}

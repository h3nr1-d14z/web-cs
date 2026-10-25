#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <prokreedz_menu>

#define PLUGIN "ProKreedz Zone System"
#define VERSION "1.2"
#define AUTHOR "OpenAI"
#define ZONE_TASK 7400
#define PREVIEW_TASK 7500

enum _:PkzZoneType
{
	PKZ_ZONE_START = 0,
	PKZ_ZONE_FINISH,
	PKZ_ZONE_COUNT
}

new Float:g_flZoneMins[PKZ_ZONE_COUNT][3]
new Float:g_flZoneMaxs[PKZ_ZONE_COUNT][3]
new bool:g_bZoneExists[PKZ_ZONE_COUNT]
new bool:g_bPlayerInside[33][PKZ_ZONE_COUNT]

new Float:g_flCornerOne[33][3]
new Float:g_flCornerTwo[33][3]
new bool:g_bHasCornerOne[33]
new bool:g_bHasCornerTwo[33]
new bool:g_bEditing[33]
new g_iSelectedZone[33]

new g_iBeamSprite
new g_iForwardReady
new g_iForwardEnter
new g_iForwardLeave
new g_szZoneFile[192]
new g_pMenuPrefix

public plugin_precache()
{
	g_iBeamSprite = precache_model("sprites/laserbeam.spr")
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)
	register_dictionary("prokreedz_zones.txt")
	register_clcmd("say /zone", "ZoneMenu", ADMIN_KICK)
	register_clcmd("say_team /zone", "ZoneMenu", ADMIN_KICK)
	register_concmd("amx_zone", "ZoneMenu", ADMIN_KICK)

	g_iForwardReady = CreateMultiForward("pkz_zones_ready", ET_IGNORE, FP_CELL, FP_CELL)
	g_iForwardEnter = CreateMultiForward("pkz_zone_enter", ET_IGNORE, FP_CELL, FP_CELL)
	g_iForwardLeave = CreateMultiForward("pkz_zone_leave", ET_IGNORE, FP_CELL, FP_CELL)
	g_pMenuPrefix = get_cvar_pointer("kz_prefix")

	set_task(0.05, "ZoneThink", ZONE_TASK, _, _, "b")
	set_task(0.5, "PreviewThink", PREVIEW_TASK, _, _, "b")
}

public plugin_cfg()
{
	new szConfigDir[128], szMap[64], szRoot[160], szZones[176]
	get_configsdir(szConfigDir, charsmax(szConfigDir))
	formatex(szRoot, charsmax(szRoot), "%s/prokreedz", szConfigDir)
	if (!dir_exists(szRoot))
		mkdir(szRoot)
	formatex(szZones, charsmax(szZones), "%s/zones", szRoot)
	if (!dir_exists(szZones))
		mkdir(szZones)
	get_mapname(szMap, charsmax(szMap))
	formatex(g_szZoneFile, charsmax(g_szZoneFile), "%s/%s.ini", szZones, szMap)
	LoadZones()

	new iReturn
	ExecuteForward(g_iForwardReady, iReturn, g_bZoneExists[PKZ_ZONE_START] ? 1 : 0, g_bZoneExists[PKZ_ZONE_FINISH] ? 1 : 0)
	server_print("[ProKreedz Zones] %s: start=%d finish=%d", szMap, g_bZoneExists[PKZ_ZONE_START], g_bZoneExists[PKZ_ZONE_FINISH])
}

public client_disconnected(id)
{
	ResetEditor(id)
	for (new i = 0; i < PKZ_ZONE_COUNT; i++)
		g_bPlayerInside[id][i] = false
}

public ZoneThink()
{
	for (new id = 1; id <= 32; id++)
	{
		if (!is_user_alive(id) || is_user_bot(id))
		{
			for (new i = 0; i < PKZ_ZONE_COUNT; i++)
				g_bPlayerInside[id][i] = false
			continue
		}

		new Float:flOrigin[3]
		pev(id, pev_origin, flOrigin)
		for (new iZone = 0; iZone < PKZ_ZONE_COUNT; iZone++)
		{
			if (!g_bZoneExists[iZone])
				continue

			new bool:bInside = PointInside(flOrigin, g_flZoneMins[iZone], g_flZoneMaxs[iZone])
			if (bInside == g_bPlayerInside[id][iZone])
				continue

			g_bPlayerInside[id][iZone] = bInside
			new iReturn
			if (bInside)
				ExecuteForward(g_iForwardEnter, iReturn, id, iZone)
			else
				ExecuteForward(g_iForwardLeave, iReturn, id, iZone)
		}
	}
}

bool:PointInside(const Float:flPoint[3], const Float:flMins[3], const Float:flMaxs[3])
{
	return flPoint[0] >= flMins[0] && flPoint[0] <= flMaxs[0]
		&& flPoint[1] >= flMins[1] && flPoint[1] <= flMaxs[1]
		&& flPoint[2] >= flMins[2] && flPoint[2] <= flMaxs[2]
}

stock KzChatPrint(id, const szMsg[], any:...)
{
	static szPrefix[16], szFormatted[192], szFinal[192]
	if (g_pMenuPrefix)
		get_pcvar_string(g_pMenuPrefix, szPrefix, charsmax(szPrefix))
	else
		copy(szPrefix, charsmax(szPrefix), "[KZ]")
	vformat(szFormatted, charsmax(szFormatted), szMsg, 3)
	formatex(szFinal, charsmax(szFinal), "^4%s^1 %s", szPrefix, szFormatted)
	if (id)
	{
		message_begin(MSG_ONE, get_user_msgid("SayText"), _, id)
		write_byte(id)
	}
	else
	{
		message_begin(MSG_ALL, get_user_msgid("SayText"))
		write_byte(1)
	}
	write_string(szFinal)
	message_end()
}

public ZoneMenu(id, iLevel, iCid)
{
	if (!cmd_access(id, iLevel, iCid, 1))
		return PLUGIN_HANDLED
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	g_bEditing[id] = true
	new szPrefix[32]
	if (g_pMenuPrefix)
		get_pcvar_string(g_pMenuPrefix, szPrefix, charsmax(szPrefix))
	else
		copy(szPrefix, charsmax(szPrefix), "[KZ]")

	new szTitle[128], szType[32]
	formatex(szType, charsmax(szType), "%L", id, g_iSelectedZone[id] == PKZ_ZONE_START ? "ZONE_START" : "ZONE_FINISH")
	formatex(szTitle, charsmax(szTitle), "\y%s Zone Menu\w - %s", szPrefix, szType)
	new iMenu = menu_create(szTitle, "ZoneMenuHandler")
	formatex(szTitle, charsmax(szTitle), g_iSelectedZone[id] == PKZ_ZONE_START ? "\y%s\w Start Zone [\ySelected\w]" : "\y%s\w Start Zone", szPrefix)
	menu_additem(iMenu, szTitle, "1")
	formatex(szTitle, charsmax(szTitle), g_iSelectedZone[id] == PKZ_ZONE_FINISH ? "\y%s\w Finish Zone [\ySelected\w]" : "\y%s\w Finish Zone", szPrefix)
	menu_additem(iMenu, szTitle, "2")
	formatex(szTitle, charsmax(szTitle), "\y%s\w Corner 1", szPrefix)
	menu_additem(iMenu, szTitle, "3")
	formatex(szTitle, charsmax(szTitle), "\y%s\w Corner 2", szPrefix)
	menu_additem(iMenu, szTitle, "4")
	formatex(szTitle, charsmax(szTitle), "\y%s\w Save Zone", szPrefix)
	menu_additem(iMenu, szTitle, "5")
	formatex(szTitle, charsmax(szTitle), "\y%s\w Delete Zone", szPrefix)
	menu_additem(iMenu, szTitle, "6")
	formatex(szTitle, charsmax(szTitle), "\y%s\w Close Editor", szPrefix)
	menu_additem(iMenu, szTitle, "7")
	PkzMenuSetNavigation(iMenu, PKZ_MENU_NAV_EXIT)
	PkzMenuDisplaySafe(id, iMenu)
	return PLUGIN_HANDLED
}

public ZoneMenuHandler(id, iMenu, iItem)
{
	if (iItem < 0)
	{
		menu_destroy(iMenu)
		return PLUGIN_HANDLED
	}

	menu_destroy(iMenu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED
	switch (iItem)
	{
		case 0:
		{
			g_iSelectedZone[id] = PKZ_ZONE_START
			g_bHasCornerOne[id] = false
			g_bHasCornerTwo[id] = false
		}
		case 1:
		{
			g_iSelectedZone[id] = PKZ_ZONE_FINISH
			g_bHasCornerOne[id] = false
			g_bHasCornerTwo[id] = false
		}
		case 2:
		{
			pev(id, pev_origin, g_flCornerOne[id])
			g_bHasCornerOne[id] = true
			KzChatPrint(id, "Corner 1 saved.")
		}
		case 3:
		{
			pev(id, pev_origin, g_flCornerTwo[id])
			g_bHasCornerTwo[id] = true
			KzChatPrint(id, "Corner 2 saved.")
		}
		case 4: SaveEditedZone(id)
		case 5: DeleteSelectedZone(id)
		case 6:
		{
			ResetEditor(id)
			return PLUGIN_HANDLED
		}
	}
	ZoneMenu(id, ADMIN_KICK, 0)
	return PLUGIN_HANDLED
}

stock SaveEditedZone(id)
{
	if (!g_bHasCornerOne[id] || !g_bHasCornerTwo[id])
	{
		KzChatPrint(id, "Set both corners first.")
		return
	}

	new iZone = g_iSelectedZone[id]
	for (new axis = 0; axis < 3; axis++)
	{
		g_flZoneMins[iZone][axis] = floatmin(g_flCornerOne[id][axis], g_flCornerTwo[id][axis])
		g_flZoneMaxs[iZone][axis] = floatmax(g_flCornerOne[id][axis], g_flCornerTwo[id][axis])
	}

	if (g_flZoneMaxs[iZone][0] - g_flZoneMins[iZone][0] < 32.0)
	{
		g_flZoneMins[iZone][0] -= 16.0
		g_flZoneMaxs[iZone][0] += 16.0
	}
	if (g_flZoneMaxs[iZone][1] - g_flZoneMins[iZone][1] < 32.0)
	{
		g_flZoneMins[iZone][1] -= 16.0
		g_flZoneMaxs[iZone][1] += 16.0
	}
	if (g_flZoneMaxs[iZone][2] - g_flZoneMins[iZone][2] < 72.0)
	{
		g_flZoneMins[iZone][2] -= 36.0
		g_flZoneMaxs[iZone][2] += 36.0
	}

	g_bZoneExists[iZone] = true
	SaveZones()
	NotifyReady()
	KzChatPrint(id, "Zone saved.")
}

stock DeleteSelectedZone(id)
{
	new iZone = g_iSelectedZone[id]
	g_bZoneExists[iZone] = false
	SaveZones()
	NotifyReady()
	KzChatPrint(id, "Zone deleted.")
}

stock NotifyReady()
{
	new iReturn
	ExecuteForward(g_iForwardReady, iReturn, g_bZoneExists[PKZ_ZONE_START] ? 1 : 0, g_bZoneExists[PKZ_ZONE_FINISH] ? 1 : 0)
}

stock ResetEditor(id)
{
	g_bEditing[id] = false
	g_bHasCornerOne[id] = false
	g_bHasCornerTwo[id] = false
}

stock SaveZones()
{
	if (file_exists(g_szZoneFile))
		delete_file(g_szZoneFile)

	new szLine[256]
	for (new iZone = 0; iZone < PKZ_ZONE_COUNT; iZone++)
	{
		if (!g_bZoneExists[iZone])
			continue
		formatex(szLine, charsmax(szLine), "%s %.3f %.3f %.3f %.3f %.3f %.3f",
			iZone == PKZ_ZONE_START ? "start" : "finish",
			g_flZoneMins[iZone][0], g_flZoneMins[iZone][1], g_flZoneMins[iZone][2],
			g_flZoneMaxs[iZone][0], g_flZoneMaxs[iZone][1], g_flZoneMaxs[iZone][2])
		write_file(g_szZoneFile, szLine)
	}
}

stock LoadZones()
{
	for (new i = 0; i < PKZ_ZONE_COUNT; i++)
		g_bZoneExists[i] = false
	if (!file_exists(g_szZoneFile))
		return

	new iFile = fopen(g_szZoneFile, "rt")
	if (!iFile)
		return

	new szLine[256], szType[16], szValue[6][24]
	while (!feof(iFile))
	{
		fgets(iFile, szLine, charsmax(szLine))
		trim(szLine)
		if (!szLine[0] || szLine[0] == ';' || szLine[0] == '#')
			continue
		parse(szLine, szType, charsmax(szType), szValue[0], 23, szValue[1], 23, szValue[2], 23, szValue[3], 23, szValue[4], 23, szValue[5], 23)
		new iZone = equali(szType, "start") ? PKZ_ZONE_START : (equali(szType, "finish") ? PKZ_ZONE_FINISH : -1)
		if (iZone == -1)
			continue
		for (new axis = 0; axis < 3; axis++)
		{
			g_flZoneMins[iZone][axis] = str_to_float(szValue[axis])
			g_flZoneMaxs[iZone][axis] = str_to_float(szValue[axis + 3])
		}
		g_bZoneExists[iZone] = true
	}
	fclose(iFile)
}

public PreviewThink()
{
	for (new id = 1; id <= 32; id++)
	{
		if (!is_user_connected(id))
			continue
		for (new iZone = 0; iZone < PKZ_ZONE_COUNT; iZone++)
		{
			if (!g_bZoneExists[iZone])
				continue
			if (g_bEditing[id] && iZone == g_iSelectedZone[id])
				DrawBox(id, g_flZoneMins[iZone], g_flZoneMaxs[iZone], 255, 128)
			else
				DrawBox(id, g_flZoneMins[iZone], g_flZoneMaxs[iZone], iZone == PKZ_ZONE_START ? 0 : 255, iZone == PKZ_ZONE_START ? 255 : 64)
		}
	}
}

stock DrawBox(id, const Float:flMins[3], const Float:flMaxs[3], iRed, iGreen)
{
	new Float:p[4][3]
	new Float:flFloorZ = flMins[2] + 1.0
	p[0][0] = flMins[0]; p[0][1] = flMins[1]
	p[1][0] = flMaxs[0]; p[1][1] = flMins[1]
	p[2][0] = flMaxs[0]; p[2][1] = flMaxs[1]
	p[3][0] = flMins[0]; p[3][1] = flMaxs[1]
	for (new i = 0; i < 4; i++)
		p[i][2] = flFloorZ

	DrawLine(id, p[0], p[1], iRed, iGreen)
	DrawLine(id, p[1], p[2], iRed, iGreen)
	DrawLine(id, p[2], p[3], iRed, iGreen)
	DrawLine(id, p[3], p[0], iRed, iGreen)
}

stock DrawLine(id, const Float:flStart[3], const Float:flEnd[3], iRed, iGreen)
{
	message_begin(MSG_ONE_UNRELIABLE, SVC_TEMPENTITY, _, id)
	write_byte(0)
	engfunc(EngFunc_WriteCoord, flStart[0]); engfunc(EngFunc_WriteCoord, flStart[1]); engfunc(EngFunc_WriteCoord, flStart[2])
	engfunc(EngFunc_WriteCoord, flEnd[0]); engfunc(EngFunc_WriteCoord, flEnd[1]); engfunc(EngFunc_WriteCoord, flEnd[2])
	write_short(g_iBeamSprite)
	write_byte(0); write_byte(0); write_byte(12); write_byte(6); write_byte(0)
	write_byte(iRed); write_byte(iGreen); write_byte(64); write_byte(220); write_byte(0)
	message_end()
}

public plugin_end()
{
	if (g_iForwardReady) DestroyForward(g_iForwardReady)
	if (g_iForwardEnter) DestroyForward(g_iForwardEnter)
	if (g_iForwardLeave) DestroyForward(g_iForwardLeave)
}

#include <amxmodx>
#include <cstrike>
#include <colorchat>
#include <fun>
#include <fakemeta>
#include <hamsandwich>
#include <sqlx>
#include <prokreedz_menu>

//#define USE_SQL

#if defined USE_SQL
 #include <sqlx>
 #include <geoip>
#endif
 
#define KZ_LEVEL ADMIN_KICK 
#define MSG MSG_ONE_UNRELIABLE
#define MAX_ENTITYS 900+15*32
#define IsOnLadder(%1) (pev(%1, pev_movetype) == MOVETYPE_FLY)  
#define VERSION "3.6 WEB"
#define PKZ_SURF_FIX_UNSTUCK_HEIGHT 0.01
#define PKZ_SURF_FIX_TRACE_HULL_HEIGHT 0.01

#define PKZ_FPS_COUNT 7
#define PKZ_MOD_COUNT 8
#define PKZ_CATEGORY_COUNT 56

enum _:PkzModBits
{
	PKZ_MOD_LOWGRAV = 1,
	PKZ_MOD_DOUBLEJUMP = 2,
	PKZ_MOD_BHOP = 4
}

enum _:PkzZoneType
{
	PKZ_ZONE_START = 0,
	PKZ_ZONE_FINISH
}

new const g_szFpsSlug[PKZ_FPS_COUNT][] =
{
	"60fps", "100fps", "200fps", "250fps", "333fps", "500fps", "1000fps"
}

new const g_szFpsName[PKZ_FPS_COUNT][] =
{
	"60 FPS", "100 FPS", "200 FPS", "250 FPS", "333 FPS", "500 FPS", "1000 FPS"
}

new const g_iFpsLimits[PKZ_FPS_COUNT] =
{
	60, 100, 200, 250, 333, 500, 1000
}

new const Float:g_flFpsSpeedLimits[PKZ_FPS_COUNT] =
{
	0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0
}

static const g_szModTag[PKZ_MOD_COUNT][] =
{
	"nomod", "lg", "dj", "dj+lg", "bhop", "bhop+lg", "bhop+dj", "bhop+dj+lg"
}

static const g_szModName[PKZ_MOD_COUNT][] =
{
	"NoMod", "LG", "DJ", "DJ+LG", "Bhop", "Bhop+LG", "Bhop+DJ", "All"
}

new g_pPkzSimpleMode
new g_pPkzSimpleBHOP
new g_pPkzSimpleDJ
new g_pPkzSimpleLG

stock PkzCalcCategoryIndex(bool:bBhop, bool:bDJ, bool:bLG, iFpsIdx)
{
	return ((bBhop ? PKZ_MOD_BHOP : 0) | (bDJ ? PKZ_MOD_DOUBLEJUMP : 0) | (bLG ? PKZ_MOD_LOWGRAV : 0)) * PKZ_FPS_COUNT + iFpsIdx
}

stock PkzGetFpsIndex(iCategory)
{
	return iCategory % PKZ_FPS_COUNT
}

stock PkzGetModIndex(iCategory)
{
	return iCategory / PKZ_FPS_COUNT
}

stock PkzGetFpsLimit(iCategory)
{
	return g_iFpsLimits[PkzGetFpsIndex(iCategory)]
}

stock Float:PkzGetSpeedLimit(iCategory)
{
	return g_flFpsSpeedLimits[PkzGetFpsIndex(iCategory)]
}

stock PkzGetCategoryName(iCategory, szName[], iLen)
{
	new iMod = PkzGetModIndex(iCategory)
	new iFps = PkzGetFpsIndex(iCategory)
	formatex(szName, iLen, "%s %s", g_szModName[iMod], g_szFpsName[iFps])
}

stock PkzGetCategorySlug(iCategory, szSlug[], iLen)
{
	new iMod = PkzGetModIndex(iCategory)
	new iFps = PkzGetFpsIndex(iCategory)
	formatex(szSlug, iLen, "%s_%s", g_szModTag[iMod], g_szFpsSlug[iFps])
}

#define SCOREATTRIB_NONE    0
#define SCOREATTRIB_DEAD    ( 1 << 0 )
#define SCOREATTRIB_BOMB    ( 1 << 1 )
#define SCOREATTRIB_VIP  ( 1 << 2 )


new g_iPlayers[32], g_iNum, g_iPlayer
new const g_szAliveFlags[] = "a" 
#define RefreshPlayersList()    get_players(g_iPlayers, g_iNum, g_szAliveFlags) 

new const FL_ONGROUND2 = ( FL_ONGROUND | FL_PARTIALGROUND | FL_INWATER |  FL_CONVEYOR | FL_FLOAT )
new const KZ_STARTFILE[] = "start.ini"
new const KZ_STARTFILE_TEMP[] = "temp_start.ini"

#if defined USE_SQL
new Handle:g_SqlTuple
new Handle:SqlConnection
new g_Error[512]
new kz_sql_host
new kz_sql_user
new kz_sql_pass
new kz_sql_db
new kz_sql_name
#else
new Float:Pro_Times[24]
new Pro_AuthIDS[24][32]
new Pro_Names[24][32]
new Pro_Date[24][32]
new Float:Noob_Tiempos[24]
new Noob_AuthIDS[24][32]
new Noob_Names[24][32]
new Noob_Date[24][32]
new Noob_CheckPoints[24]
new Noob_GoChecks[24]
new Noob_Weapon[24][32]
#endif

new Float:Checkpoints[33][2][3]
new Float:timer_time[33]
new Float:g_pausetime[33]
new Float:antihookcheat[33]
new Float:SpecLoc[33][3]
new Float:NoclipPos[33][3]
new Float:PauseOrigin[33][3]
new Float:SavedStart[33][3]
new hookorigin[33][3]
new Float:DefaultStartPos[3]

new Float:SavedTime[33]
new SavedChecks[33]
new SavedGoChecks[33]
new SavedScout[33]
new SavedOrigins[33][3]

new bool:g_bCpAlternate[33]
new bool:timer_started[33]
new bool:IsPaused[33]
new bool:WasPaused[33]
new bool:firstspawn[33]
new bool:canusehook[33]
new bool:ishooked[33]
new bool:user_has_scout[33]
new bool:NightVisionUse[33]
new bool:HealsOnMap
new bool:gViewInvisible[33]
new bool:gMarkedInvisible[33] = { true, ...};
new bool:gWaterInvisible[33]
new bool:gWaterEntity[MAX_ENTITYS]
new bool:gWaterFound
new bool:DefaultStart
new bool:AutoStart[33]
new Float:g_flStartZoneCenter[3]
new bool:g_bStartZoneCached

new Trie:g_tStarts
new Trie:g_tStops;

new checknumbers[33]
new gochecknumbers[33]
new chatorhud[33]
new ShowTime[33]
new g_szMapName[64]
new Kzdir[128]
new SavePosDir[128]
new prefix[33]
#if !defined USE_SQL
new Topdir[128]
#endif

new kz_checkpoints
new kz_cheatdetect
new kz_spawn_mainmenu
new kz_show_timer
new kz_chatorhud
new kz_hud_color
new kz_prefix
new hud_message
new kz_other_weapons
new kz_maxspeedmsg
new kz_drop_weapons
new kz_remove_drops
new kz_pick_weapons
new kz_reload_weapons
new kz_show_speed
new kz_use_radio
new kz_hook_prize
new kz_hook_enabled
new kz_hook_require_finish
new kz_hook_sound
new kz_hook_speed
new kz_pause
new kz_noclip_pause
new kz_nvg
new kz_nvg_colors
new kz_vip
new kz_respawn_ct
new kz_save_pos
new kz_save_pos_gochecks

new g_iCategory[33]
new g_iFpsViolations[33]
new bool:g_bRunValid[33]
new bool:g_bRecordPending[33]
new Float:g_flSurfFixStartVelocity[33][3]
new bool:g_bInsideStartZone[33]
new bool:g_bZoneStartAvailable
new bool:g_bZoneFinishAvailable
new Handle:g_hLocalTuple = Empty_Handle
new Handle:g_hMysqlTuple = Empty_Handle
new bool:g_bLocalDbReady
new bool:g_bMysqlReady
new g_szDbStatus[128]
new pkz_mysql_enabled
new pkz_mysql_host
new pkz_mysql_user
new pkz_mysql_pass
new pkz_mysql_db
new pkz_mysql_server
new g_iForwardRunStarted
new g_iForwardRunReset
new g_iForwardRunFinished
new kz_semiclip
new kz_semiclip_transparency
new kz_spec_saves
new kz_save_autostart
new kz_top15_authid
new kz_web_motd_enabled
new kz_web_motd_url
new Sbeam = 0
new g_pPkzModEnabled
new g_pPkzModDefault
new g_pPkzModBhopStyle
new g_pPkzModFallDamage
new g_szPendingRunType[33][8]
new g_szTopRunType[33][8]
new g_szPlayerKey[33][64]
new g_szPlayerAuthId[33][64]

// Mod state (merged from kz_mods.sma)
new bool:g_bPkzModBHOP[33]
new bool:g_bPkzModDJ[33]
new bool:g_bPkzModLG[33]
new bool:g_bPkzPrevJump[33]
new g_iPkzJumpCount[33]
new g_iPkzFpsIndex[33]
#if defined USE_SQL
new kz_sql_files
#endif

new const other_weapons[8] = 
{
	CSW_SCOUT, CSW_P90, CSW_FAMAS, CSW_SG552,
	CSW_M4A1, CSW_M249, CSW_AK47, CSW_AWP
}

new const other_weapons_name[8][] = 
{
	"weapon_scout", "weapon_p90", "weapon_famas", "weapon_sg552",
	"weapon_m4a1", "weapon_m249", "weapon_ak47", "weapon_awp"
}

new const g_weaponsnames[][] =
{
	"", // NULL
	"p228", "shield", "scout", "hegrenade", "xm1014", "c4",
	"mac10", "aug", "smokegrenade", "elite", "fiveseven",
	"ump45", "sg550", "galil", "famas", "usp", "glock18",
	"awp", "mp5navy", "m249", "m3", "m4a1", "tmp", "g3sg1",
	"flashbang", "deagle", "sg552", "ak47", "knife", "p90",
	"glock",  "elites", "fn57", "mp5", "vest", "vesthelm", 
	"flash", "hegren", "sgren", "defuser", "nvgs", "primammo", 
	"secammo", "km45", "9x19mm", "nighthawk", "228compact", 
	"12gauge", "autoshotgun", "mp", "c90", "cv47", "defender", 
	"clarion", "krieg552", "bullpup", "magnum", "d3au1", 
	"krieg550"
}

new const g_block_commands[][]=
{
	"buy", "buyammo1", "buyammo2", "buyequip",
	"cl_autobuy", "cl_rebuy", "cl_setautobuy", "cl_setrebuy"

}

#if defined USE_SQL
enum
{
	TOP_NULL,
	PRO_TOP,
	NUB_TOP,
	LAST_PRO10,
	PRO_RECORDS,
	PLAYERS_RANKING,
	MAPS_STATISTIC
}
#endif

stock PkzGetSimpleCategoryName(id, szName[], iLen)
{
	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		copy(szName, iLen, "Simple")
		return
	}
	PkzGetCategoryName(g_iCategory[id], szName, iLen)
}

stock PkzGetQueryCategorySlug(iCategory, szSlug[], iLen)
{
	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		copy(szSlug, iLen, "simple")
		return
	}
	PkzGetCategorySlug(iCategory, szSlug, iLen)
}

// =================================================================================================
 
public plugin_natives()
{
	register_library("prokreedz")
	register_native("pkz_get_user_category", "native_get_user_category")
	register_native("pkz_is_user_running", "native_is_user_running")
	register_native("pkz_is_user_paused", "native_is_user_paused")
	register_native("pkz_get_category_slug", "native_get_category_slug")
	register_native("pkz_get_user_mod", "native_get_user_mod")
	register_native("pkz_set_user_mod", "native_set_user_mod")
	register_native("pkz_get_category_name", "native_get_category_name")
	register_native("pkz_get_simple_mode", "native_get_simple_mode")
	register_native("pkz_get_player_key", "native_get_player_key")
	register_native("pkz_open_main_menu", "native_open_main_menu")
	register_native("pkz_enter_spectator", "native_enter_spectator")
}

public plugin_init()
{
	register_plugin("ProKreedz", VERSION, "nucLeaR & p4ddY")

	kz_checkpoints = register_cvar("kz_checkpoints","1")
	kz_cheatdetect = register_cvar("kz_cheatdetect","1")
	kz_spawn_mainmenu = register_cvar("kz_spawn_mainmenu", "1")
	kz_show_timer = register_cvar("kz_show_timer", "1")
	kz_chatorhud = register_cvar("kz_chatorhud", "2") 
	kz_prefix = register_cvar("kz_prefix", "[KZ]")
	kz_hud_color = register_cvar("kz_hud_color", "12 122 221")
	kz_other_weapons = register_cvar("kz_other_weapons","1") 
	kz_drop_weapons = register_cvar("kz_drop_weapons", "0")
	kz_remove_drops = register_cvar("kz_remove_drops", "1")
	kz_pick_weapons = register_cvar("kz_pick_weapons", "0")
	kz_reload_weapons = register_cvar("kz_reload_weapons", "0")
	kz_maxspeedmsg = register_cvar("kz_maxspeedmsg","1")
	kz_hook_enabled = register_cvar("kz_hook_enabled", "1")
	kz_hook_require_finish = register_cvar("kz_hook_require_finish", "0")
	kz_hook_prize = register_cvar("kz_hook_prize","1")
	kz_hook_sound = register_cvar("kz_hook_sound","1")
	kz_hook_speed = register_cvar("kz_hook_speed", "300.0")
	kz_show_speed = register_cvar("kz_show_speed", "1")
	kz_use_radio = register_cvar("kz_use_radio", "0")
	kz_pause = register_cvar("kz_pause", "1")
	kz_noclip_pause = register_cvar("kz_noclip_pause", "1")
	kz_nvg = register_cvar("kz_nvg","1")
	kz_nvg_colors = register_cvar("kz_nvg_colors","5 0 255")
	kz_vip = register_cvar("kz_vip","1")
	kz_respawn_ct = register_cvar("kz_respawn_ct", "1")
	kz_semiclip = register_cvar("kz_semiclip", "1")
	kz_semiclip_transparency = register_cvar ("kz_semiclip_transparency", "85")
	kz_spec_saves = register_cvar("kz_spec_saves", "1")
	kz_save_autostart = register_cvar("kz_save_autostart", "1")
	kz_top15_authid = register_cvar("kz_top15_authid", "1")
	kz_web_motd_enabled = register_cvar("kz_web_motd_enabled", "0")
	kz_web_motd_url = register_cvar("kz_web_motd_url", "")
	kz_save_pos = register_cvar("kz_save_pos", "1")
	kz_save_pos_gochecks = register_cvar("kz_save_pos_gochecks", "1")
	pkz_mysql_enabled = register_cvar("pkz_mysql_enabled", "0")
	pkz_mysql_host = register_cvar("kz_sql_host", "")
	pkz_mysql_user = register_cvar("kz_sql_user", "")
	pkz_mysql_pass = register_cvar("kz_sql_pass", "", FCVAR_PROTECTED)
	pkz_mysql_db = register_cvar("kz_sql_db", "")
	pkz_mysql_server = register_cvar("kz_sql_server", "")
#if defined USE_SQL
	kz_sql_files = register_cvar("kz_sql_files", "") // Path of the PHP files
#endif

	// Simple mode CVars
	g_pPkzSimpleMode = register_cvar("kz_simple_mode", "0")
	g_pPkzSimpleBHOP = register_cvar("kz_bunnyhop", "1")
	g_pPkzSimpleDJ = register_cvar("kz_doublejump", "1")
	g_pPkzSimpleLG = register_cvar("kz_lowgrav", "0")

	// Mod CVars (merged from kz_mods.sma)
	g_pPkzModEnabled = register_cvar("kz_mod_enabled", "1")
	g_pPkzModDefault = register_cvar("kz_mod_default", "nobhop")
	g_pPkzModBhopStyle = register_cvar("bhop_style", "2")
	g_pPkzModFallDamage = register_cvar("kz_mod_falldamage", "1.0")

	register_clcmd("top15_cat", "PkzCmdTop15Cat")
#if defined USE_SQL
	kz_sql_host = register_cvar("kz_sql_host", "") // Host of DB
	kz_sql_user = register_cvar("kz_sql_user", "") // Username of DB
	kz_sql_pass = register_cvar("kz_sql_pass", "", FCVAR_PROTECTED) // Password for DB user
	kz_sql_db = register_cvar("kz_sql_db", "") // DB Name for the top 15
	kz_sql_name = register_cvar("kz_sql_server", "") // Name of server
	#endif
	
	register_clcmd("/cp","CheckPoint")
	register_clcmd("drop", "BlockDrop")
	register_clcmd("/gc", "GoCheck")
	register_clcmd("+hook","hook_on")
	register_clcmd("-hook","hook_off")
	register_concmd("kz_hook","give_hook", KZ_LEVEL, "<name|#userid|steamid|@ALL> <on/off>")
	register_concmd("amx_simple","CmdSimpleMode", ADMIN_CFG, "<0|1> - Toggle simple mode")
	register_concmd("pkz_db_status", "PkzDbStatus", ADMIN_CFG, "- Show ProKreedz database status")
	register_concmd("nightvision","ToggleNVG")
	register_clcmd("radio1", "BlockRadio") 
	register_clcmd("radio2", "BlockRadio") 
	register_clcmd("radio3", "BlockRadio") 
	register_clcmd("/tp","GoCheck")
	
	kz_register_saycmd("cp","CheckPoint",0)
	kz_register_saycmd("chatorhud", "ChatHud", 0)
	kz_register_saycmd("ct","ct",0)
	kz_register_saycmd("gc", "GoCheck",0)
	kz_register_saycmd("gocheck", "GoCheck",0)
	kz_register_saycmd("god", "GodMode",0)
	kz_register_saycmd("godmode", "GodMode", 0)
	kz_register_saycmd("invis", "InvisMenu", 0)
	kz_register_saycmd("kz", "kz_menu", 0)
	kz_register_saycmd("menu","kz_menu", 0)
	kz_register_saycmd("nc", "noclip", 0)
	kz_register_saycmd("noclip", "noclip", 0)
	kz_register_saycmd("noob10", "NoobTop15Show", 0)
	kz_register_saycmd("noob15", "NoobTop15Show", 0)
	kz_register_saycmd("noob", "NoobMotdShow", 0)
	kz_register_saycmd("nub10", "NoobTop15Show", 0)
	kz_register_saycmd("nub15", "NoobTop15Show", 0)
	kz_register_saycmd("pro", "ProMotdShow", 0)
	kz_register_saycmd("pause", "Pause", 0)
	kz_register_saycmd("category", "PkzModMenu", 0)
	kz_register_saycmd("fps", "PkzFPSMenu", 0)
	kz_register_saycmd("pinvis", "cmdInvisible", 0)
	kz_register_saycmd("pro10", "ProTop15Show", 0)
	kz_register_saycmd("pro15", "ProTop15Show", 0)
	kz_register_saycmd("rank", "CategoryRankShow", 0)
	kz_register_saycmd("reset", "reset_checkpoints", 0)
	kz_register_saycmd("respawn", "goStart", 0) 
	kz_register_saycmd("savepos", "SavePos", 0)
	kz_register_saycmd("scout", "cmdScout", 0)
	kz_register_saycmd("setstart", "setStart", KZ_LEVEL)
	kz_register_saycmd("showtimer", "ShowTimer_Menu", 0)
	kz_register_saycmd("spec", "ct", 0)
	kz_register_saycmd("start", "goStart", 0)
	kz_register_saycmd("stuck", "Stuck", 0)
	kz_register_saycmd("teleport", "GoCheck", 0)
	kz_register_saycmd("timer", "ShowTimer_Menu", 0)
	kz_register_saycmd("top15", "ProTop15Show",0)
	kz_register_saycmd("top10", "ProTop15Show",0)
	kz_register_saycmd("top", "ProTop15Show",0)

	kz_register_saycmd("tp", "GoCheck",0)
	kz_register_saycmd("usp", "cmdUsp", 0)
	kz_register_saycmd("weapons", "weapons", 0)
	kz_register_saycmd("guns", "weapons", 0)	
	kz_register_saycmd("winvis", "cmdWaterInvisible", 0)
	// Mod commands (merged from kz_mods.sma)
	kz_register_saycmd("mod", "PkzModMenu", 0)
	kz_register_saycmd("bhop", "PkzModMenu", 0)

	#if defined USE_SQL
	kz_register_saycmd("prorecords", "ProRecs_show", 0)
	kz_register_saycmd("prorecs", "ProRecs_show", 0)
	#endif
	
	register_event("CurWeapon", "curweapon", "be", "1=1")
	register_event( "StatusValue", "EventStatusValue", "b", "1>0", "2>0" );

	register_forward(FM_AddToFullPack, "FM_client_AddToFullPack_Post", 1) 
	register_forward(FM_CmdStart, "PkzCmdStart")
	register_forward(FM_CmdEnd, "PkzCmdEnd")
	register_forward(FM_PlayerPreThink, "PkzPlayerPreThink")
	register_forward(FM_UpdateClientData, "PkzUpdateClientData")

	RegisterHam( Ham_Player_Jump, "player", "PkzPlayerJump")
	RegisterHam( Ham_Player_PreThink, "player", "Ham_CBasePlayer_PreThink_Post", 1)
	RegisterHam( Ham_Use, "func_button", "fwdUse", 0)
	RegisterHam( Ham_Killed, "player", "Ham_CBasePlayer_Killed_Post", 1)
	RegisterHam( Ham_Touch, "weaponbox", "FwdSpawnWeaponbox" )
	RegisterHam( Ham_Spawn, "player", "FwdHamPlayerSpawn", 1 )
	RegisterHam( Ham_Touch, "weaponbox", "GroundWeapon_Touch")
	RegisterHam( Ham_TakeDamage, "player", "PkzHamTakeDamage") 

	register_message( get_user_msgid( "ScoreAttrib" ), "MessageScoreAttrib" )
	register_dictionary("prokreedz.txt")
	get_pcvar_string(kz_prefix, prefix, 31)
	get_mapname(g_szMapName, 63)
	set_msg_block(get_user_msgid("ClCorpse"), BLOCK_SET)
	set_task(0.5,"timer_task",2000,"",0,"ab")   
	set_task(0.3, "PkzStorageInit")
	#if defined USE_SQL
	set_task(0.2, "plugin_sql")
	#endif
	
	new kreedz_cfg[128], ConfigDir[64]
	get_configsdir( ConfigDir, 64)
	formatex(Kzdir,128, "%s/kz", ConfigDir)
	if( !dir_exists(Kzdir) )
		mkdir(Kzdir)
	
	#if !defined USE_SQL
	formatex(Topdir,128, "%s/top15", Kzdir)
	if( !dir_exists(Topdir) )
		mkdir(Topdir)
	#endif
	
	formatex(SavePosDir, 128, "%s/savepos", Kzdir)
	if( !dir_exists(SavePosDir) )
		mkdir(SavePosDir)
    
	formatex(kreedz_cfg,128,"%s/kreedz.cfg", Kzdir)
        
	if( file_exists( kreedz_cfg ) )
	{
		server_exec()
		server_cmd("exec %s",kreedz_cfg)
	}
	
	for(new i = 0; i < sizeof(g_block_commands) ; i++) 
		register_clcmd(g_block_commands[i], "BlockBuy")

	g_tStarts = TrieCreate( )
	g_tStops  = TrieCreate( )

	new const szStarts[ ][ ] =
	{
		"counter_start", "clockstartbutton", "firsttimerelay", "but_start", "counter_start_button",
		"multi_start", "timer_startbutton", "start_timer_emi", "gogogo"
	}

	new const szStops[ ][ ]  =
	{
		"counter_off", "clockstopbutton", "clockstop", "but_stop", "counter_stop_button",
		"multi_stop", "stop_counter", "m_counter_end_emi"
	}

	for( new i = 0; i < sizeof szStarts; i++ )
		TrieSetCell( g_tStarts, szStarts[ i ], 1 )
	
	for( new i = 0; i < sizeof szStops; i++ )
		TrieSetCell( g_tStops, szStops[ i ], 1 )

	g_iForwardRunStarted = CreateMultiForward("pkz_run_started", ET_IGNORE, FP_CELL, FP_CELL, FP_STRING)
	g_iForwardRunReset = CreateMultiForward("pkz_run_reset", ET_IGNORE, FP_CELL)
	g_iForwardRunFinished = CreateMultiForward("pkz_run_finished", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_CELL, FP_STRING)
}

#if defined USE_SQL
public plugin_sql()
{
	new host[64], user[64], pass[64], db[64]
	
	get_pcvar_string(kz_sql_host, host, 63)
	get_pcvar_string(kz_sql_user, user, 63)
	get_pcvar_string(kz_sql_pass, pass, 63)
	get_pcvar_string(kz_sql_db, db, 63)
	
	g_SqlTuple = SQL_MakeDbTuple(host, user, pass, db)
	
	new ErrorCode
	SqlConnection = SQL_Connect(g_SqlTuple,ErrorCode,g_Error,511)
	
	if(!SqlConnection) 
	{
		server_print("[KZ] TOP15 SQL: Could not connect to SQL database.!")
		log_amx("[KZ] TOP15 SQL: Could not connect to SQL database.")
		return pause("a")
	}
	
	new createinto[1001]
	formatex(createinto, 1000, "CREATE TABLE IF NOT EXISTS `kz_pro15` (`mapname` varchar(64) NOT NULL, `authid` varchar(64) NOT NULL, `country` varchar(6) NOT NULL, `name` varchar(64) NOT NULL, `time` decimal(65,2)   NOT NULL, `date` datetime NOT NULL, `weapon` varchar(64) NOT NULL, `server` varchar(64) NOT NULL)")
	SQL_ThreadQuery(g_SqlTuple,"QueryHandle", createinto)
	formatex(createinto, 1000, "CREATE TABLE IF NOT EXISTS `kz_nub15` (`mapname` varchar(64) NOT NULL, `authid` varchar(64) NOT NULL, `country` varchar(6) NOT NULL, `name` varchar(64) NOT NULL, `time`decimal(65,2)  NOT NULL, `date` datetime NOT NULL, `weapon` varchar(64) NOT NULL, `server` varchar(64) NOT NULL, `checkpoints` real NOT NULL, `gocheck` real NOT NULL)")
	SQL_ThreadQuery(g_SqlTuple,"QueryHandle", createinto)
	
	return PLUGIN_CONTINUE
}

public QueryHandle(iFailState, Handle:hQuery, szError[], iErrnum, cData[], iSize, Float:fQueueTime)
{
	if( iFailState != TQUERY_SUCCESS )
	{
		log_amx("[KZ] TOP15 SQL: SQL Error #%d - %s", iErrnum, szError)
		ColorChat(0, GREEN,  "%s^x01: Warning the SQL Tops can not be saved.", prefix)
	}

	server_print("[KZ] Server Sending Info to SQL Server")
	
	return PLUGIN_CONTINUE
}
#endif

public plugin_precache()
{
	hud_message = CreateHudSyncObj()
	RegisterHam( Ham_Spawn, "func_door", "FwdHamDoorSpawn", 1 )
	precache_sound("weapons/xbow_hit2.wav")
	Sbeam = precache_model("sprites/laserbeam.spr")
}

public plugin_cfg()
{
	#if !defined USE_SQL
	for (new i = 0 ; i < 15; ++i)
	{
		Pro_Times[i] = 999999999.00000;
		Noob_Tiempos[i] = 999999999.00000;
	}

	read_pro15()
	read_Noob15()
	#endif
	
	new startcheck[100], data[256], map[64], x[13], y[13], z[13];
	formatex(startcheck, 99, "%s/%s", Kzdir, KZ_STARTFILE)
	new f = fopen(startcheck, "rt" )
	while( !feof( f ) )
	{
		fgets( f, data, sizeof data - 1 )
		parse( data, map, 63, x, 12, y, 12, z, 12)
			
		if( equali( map, g_szMapName ) )
		{
			DefaultStartPos[0] = str_to_float(x)
			DefaultStartPos[1] = str_to_float(y)
			DefaultStartPos[2] = str_to_float(z)
			
			DefaultStart = true
			break;
		}
	}
	fclose(f)

	new ent = -1;
	while( ( ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "func_water") ) != 0 )
	{
		if( !gWaterFound )
		{
			gWaterFound = true;
		}

		gWaterEntity[ent] = true;
	}
	
	ent = -1;
	while( ( ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "func_illusionary") ) != 0 )
	{
		if( pev( ent, pev_skin ) ==  CONTENTS_WATER )
		{
			if( !gWaterFound )
			{
				gWaterFound = true;
			}
	
			gWaterEntity[ent] = true;
		}
	}
	
	ent = -1;
	while( ( ent = engfunc(EngFunc_FindEntityByString, ent, "classname", "func_conveyor") ) != 0 )
	{
		if( pev( ent, pev_spawnflags ) == 3 )
		{
			if( !gWaterFound )
			{
				gWaterFound = true;
			}
	
			gWaterEntity[ent] = true;
		}
	}
}

public client_command(id)
{

	new sArg[13];
	if( read_argv(0, sArg, 12) > 11 )
	{
		return PLUGIN_CONTINUE;
	}
	
	for( new i = 0; i < sizeof(g_weaponsnames); i++ )
	{
		if( equali(g_weaponsnames[i], sArg, 0) )
		{
			return PLUGIN_HANDLED;
		}
	}
	return PLUGIN_CONTINUE;
}

// =================================================================================================
// Global Functions
// =================================================================================================

public Pause(id)
{
	
	if (get_pcvar_num(kz_pause) == 0)
	{	
		kz_chat(id, "%L", id, "KZ_PAUSE_DISABLED")
		
		return PLUGIN_HANDLED
	}
	
	if(! is_user_alive(id) )
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		
		return PLUGIN_HANDLED
	}


	if(!IsPaused[id]) 
	{
		if(! timer_started[id])
		{
			kz_chat(id, "%L", id, "KZ_TIMER_NOT_STARTED")
			return PLUGIN_HANDLED
		}

		g_pausetime[id] = get_gametime() - timer_time[id]
		timer_time[id] = 0.0
		IsPaused[id] = true
		kz_chat(id, "%L", id, "KZ_PAUSE_ON")
		set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN)
		pev(id, pev_origin, PauseOrigin[id])
			
	}
	else
	{
			if(timer_started[id])
			{
				kz_chat(id, "%L", id, "KZ_PAUSE_OFF")
				if(get_user_noclip(id))
					noclip(id)
				timer_time[id] = get_gametime() - g_pausetime[id] 
			}
			IsPaused[id] = false
			set_pev(id, pev_flags, pev(id, pev_flags) & ~FL_FROZEN)
	}
		
	return PLUGIN_HANDLED
}

public timer_task()
{
	new Alive[32], Dead[32], alivePlayers, deadPlayers;
	get_players(Alive, alivePlayers, "ach")
	get_players(Dead, deadPlayers, "bch")

	if ( get_pcvar_num(kz_show_timer) > 0 )
	{
		for(new i=0;i<alivePlayers;i++)
		{
			if( timer_started[Alive[i]])
			{
				new Float:kreedztime = get_gametime() - (IsPaused[Alive[i]] ? get_gametime() - g_pausetime[Alive[i]] : timer_time[Alive[i]])

				if( ShowTime[Alive[i]] == 1 )
				{
					new colors[12], r[4], g[4], b[4];
					new imin = floatround(kreedztime / 60.0,floatround_floor)
					new isec = floatround(kreedztime - imin * 60.0,floatround_floor)
					get_pcvar_string(kz_hud_color, colors, 11)
					parse(colors, r, 3, g, 3, b, 4)
						
					set_hudmessage(str_to_num(r), str_to_num(g), str_to_num(b), 0.40, 0.10, 0, 0.0, 1.0, 0.0, 0.0, 1)	
					show_hudmessage(Alive[i], "Time: %02d:%02d | CP: %d | GC: %d %s", imin, isec, checknumbers[Alive[i]], gochecknumbers[Alive[i]], IsPaused[Alive[i]] ? "| *Paused*" : "") 
				}
				else
				if( ShowTime[Alive[i]] == 2 )
				{
					kz_showtime_roundtime(Alive[i], floatround(kreedztime))
				}
			}
				
		}
		for(new i=0;i<deadPlayers;i++)
		{
			new specmode = pev(Dead[i], pev_iuser1)
			if(specmode == 2 || specmode == 4)
			{
				new target = pev(Dead[i], pev_iuser2)
				if(target != Dead[i])
					if(is_user_alive(target) && timer_started[target])
					{
						new name[32], colors[12], r[4], g[4], b[4];
						get_user_name (target, name, 31)

						new Float:kreedztime = get_gametime() - (IsPaused[target] ? get_gametime() - g_pausetime[target] : timer_time[target])
						new imin = floatround(kreedztime / 60.0,floatround_floor)
						new isec = floatround(kreedztime - imin * 60.0,floatround_floor)

						get_pcvar_string(kz_hud_color, colors, 11)
						parse(colors, r, 3, g, 3, b, 4)

						set_hudmessage(str_to_num(r), str_to_num(g), str_to_num(b), -1.0, 0.46, 0, 0.0, 1.0, 0.0, 0.0, 1)
						show_hudmessage(Dead[i], "Time: %02d:%02d | CP: %d | GC: %d %s", imin, isec, checknumbers[target], gochecknumbers[target], IsPaused[target] ? "| *Paused*" : "") 	
					}
			}
		}
	}

	if ( get_pcvar_num(kz_show_speed) > 0 )
	{
		for(new i=0;i<alivePlayers;i++)
		{
			new id = Alive[i]
			new Float:flVel[3]
			pev(id, pev_velocity, flVel)
			new iSpeed = floatround(floatsqroot(flVel[0]*flVel[0] + flVel[1]*flVel[1]))
			set_hudmessage(255, 255, 255, -1.0, 0.63, 0, 0.0, 0.5, 0.0, 0.0, 2)
			show_hudmessage(id, "%d", iSpeed)
		}
		for(new i=0;i<deadPlayers;i++)
		{
			new specmode = pev(Dead[i], pev_iuser1)
			if(specmode == 2 || specmode == 4)
			{
				new target = pev(Dead[i], pev_iuser2)
				if(target != Dead[i] && is_user_alive(target))
				{
					new Float:flVel[3]
					pev(target, pev_velocity, flVel)
					new iSpeed = floatround(floatsqroot(flVel[0]*flVel[0] + flVel[1]*flVel[1]))
					set_hudmessage(255, 255, 255, -1.0, 0.63, 0, 0.0, 0.5, 0.0, 0.0, 2)
					show_hudmessage(Dead[i], "%d", iSpeed)
				}
			}
		}
	}
}

// ============================ Block Commands ================================


public BlockRadio(id)
{
	if (get_pcvar_num(kz_use_radio) == 1)
		return PLUGIN_CONTINUE
	return PLUGIN_HANDLED
}

public BlockDrop(id)
{
	if (get_pcvar_num(kz_drop_weapons) == 1)
		return PLUGIN_CONTINUE
	return PLUGIN_HANDLED
}

public BlockBuy(id)
{
	return PLUGIN_HANDLED
}

public CmdRespawn(id)
{
	if ( get_user_team(id) == 3 ) 
		return PLUGIN_HANDLED
	else
		ExecuteHamB(Ham_CS_RoundRespawn, id)

	return PLUGIN_HANDLED
}

public ChatHud(id)
{
	if(get_pcvar_num(kz_chatorhud) == 0)
	{
		ColorChat(id, GREEN,  "%s^x01 %L", id, "KZ_CHECKPOINT_OFF", prefix)
		return PLUGIN_HANDLED
	}
	if(chatorhud[id] == -1)
		++chatorhud[id];
		
	++chatorhud[id];
	
	if(chatorhud[id] == 3)
		chatorhud[id] = 0;
	else
		kz_chat(id, "%L", id, "KZ_CHATORHUD", chatorhud[id] == 1 ? "Sohbet" : "HUD")
		
	return PLUGIN_HANDLED
}

public ct(id)
{
	if (IsPaused[id])
	{
		kz_chat(id, "%L", id, "KZ_SPEC_PAUSE")
		return PLUGIN_HANDLED
	}

	new CsTeams:team = cs_get_user_team(id)
	if (team == CS_TEAM_CT) 
	{
		if( !( pev( id, pev_flags ) & FL_ONGROUND2 ) && timer_started[id] ) 
			return PLUGIN_HANDLED

		if (get_pcvar_num(kz_spec_saves) == 1)
		{
			pev(id, pev_origin, SpecLoc[id])

			if ( timer_started[id] )
			{
				if ( IsPaused[id] )
				{
					Pause(id)
					WasPaused[id]=true
				}

				g_pausetime[id] =   get_gametime() - timer_time[id]
				timer_time[id] = 0.0
				kz_chat(id, "%L", id, "KZ_PAUSE_ON")
			}
		}

		if(gViewInvisible[id])
			gViewInvisible[id] = false	

		cs_set_user_team(id,CS_TEAM_SPECTATOR)
		set_pev(id, pev_solid, SOLID_NOT)
		set_pev(id, pev_movetype, MOVETYPE_FLY)
		set_pev(id, pev_effects, EF_NODRAW)
		set_pev(id, pev_deadflag, DEAD_DEAD)
	}
	else 
	{
		cs_set_user_team(id,CS_TEAM_CT)
		set_pev(id, pev_effects, 0)
		set_pev(id, pev_movetype, MOVETYPE_WALK)
		set_pev(id, pev_deadflag, DEAD_NO)
		set_pev(id, pev_takedamage, DAMAGE_AIM)
		CmdRespawn(id)
		give_item(id,"weapon_knife")
		give_item(id,"weapon_usp") 
		cs_set_user_bpammo(id, CSW_USP, 36)

		if (get_pcvar_num(kz_spec_saves) == 1)
		{
			set_pev(id, pev_origin, SpecLoc[id])
			if ( timer_started [id] )
				timer_time[id] = get_gametime() - g_pausetime[id] + timer_time[id]
			if( WasPaused[id] )
			{
				Pause(id)
				WasPaused[id]=false
			}
		}
	}
	return PLUGIN_HANDLED
}


//=================== Weapons ==============
public curweapon(id)
{ 
/*
	if(get_pcvar_num(kz_maxspeedmsg) == 1 && is_user_alive(id))
	{
		new clip, ammo, speed, 
 		switch(get_user_weapon(id,clip,ammo))
		{
			case CSW_SCOUT: speed = 260
			case CSW_C4, CSW_P228, CSW_MAC10, CSW_MP5NAVY, CSW_USP, CSW_TMP, CSW_FLASHBANG, CSW_DEAGLE, CSW_GLOCK18, CSW_SMOKEGRENADE, CSW_ELITE, CSW_FIVESEVEN, CSW_UMP45, CSW_HEGRENADE, CSW_KNIFE:   speed = 250
			case CSW_P90:   speed = 245
			case CSW_XM1014, CSW_AUG, CSW_GALIL, CSW_FAMAS: speed = 240
			case CSW_SG552:  speed = 235
			case CSW_M3, CSW_M4A1:   speed= 230
			case CSW_AK47:   speed = 221
			case CSW_M249:   speed = 220
			case CSW_G3SG1, CSW_SG550, CSW_AWP: speed = 210				
  		}
		kz_hud_message(id,"%L",id, "KZ_WEAPONS_SPEED",speed)
	}
 */
 	static last_weapon[33];
	static weapon_active, weapon_num
	weapon_active = read_data(1)
	weapon_num = read_data(2)
	
 	if( ( weapon_num != last_weapon[id] ) && weapon_active && get_pcvar_num(kz_maxspeedmsg) == 1)
	{
		last_weapon[id] = weapon_num;
		
		static Float:maxspeed;
		pev(id, pev_maxspeed, maxspeed );
		
		if( maxspeed < 0.0 )
			maxspeed = 250.0;
		
		kz_hud_message(id,"%L",id, "KZ_WEAPONS_SPEED",floatround( maxspeed, floatround_floor ));
	}
	return PLUGIN_HANDLED
}
 
public weapons(id)
{
	if(!is_user_alive(id))
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}
	
	if(get_pcvar_num(kz_other_weapons) == 0)
	{	
		kz_chat(id, "%L", id, "KZ_OTHER_WEAPONS_ZERO")
		return PLUGIN_HANDLED
	}
	
	if (timer_started[id])
	{
		kz_chat(id, "%L", id, "KZ_WEAPONS_IN_RUN")
		return PLUGIN_HANDLED
	}

	for(new i = 0; i < 8; i++)
		if( !user_has_weapon(id, other_weapons[i]) )
		{
			new item;
			item = give_item(id, other_weapons_name[i] );
			cs_set_weapon_ammo(item, 0);
		}
					
	if( !user_has_weapon(id, CSW_USP) )
		cmdUsp(id)
		
	return PLUGIN_HANDLED
}


// ========================= Scout =======================
public cmdScout(id)
{
	if (timer_started[id])
		user_has_scout[id] = true
		
	strip_user_weapons(id)
	give_item(id,"weapon_usp")
	give_item(id,"weapon_knife")
	if( !user_has_weapon(id, CSW_SCOUT))
		give_item(id,"weapon_scout")
	
	return PLUGIN_HANDLED
}

public cmdUsp(id)
{
	give_item(id,"weapon_usp")
	give_item(id,"weapon_knife")
	
	return PLUGIN_HANDLED
}

// ========================== Start location =================

public goStart(id)
{
	if( !is_user_alive( id ) )
	{		
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}

	if (IsPaused[id])
	{
		kz_chat(id, "%L", id, "KZ_TELEPORT_PAUSE")
		return PLUGIN_HANDLED
	}

	if(get_pcvar_num(kz_save_autostart) == 1 && AutoStart [id] )
	{
		set_pev(id, pev_velocity, Float:{0.0, 0.0, 0.0})
		set_pev( id, pev_flags, pev(id, pev_flags) | FL_DUCKING )
		set_pev(id, pev_origin, SavedStart [id] )

		kz_chat(id, "%L", id, "KZ_START")		
	}
	else if ( DefaultStart )
	{
		set_pev(id, pev_velocity, Float:{0.0, 0.0, 0.0})
		set_pev(id, pev_origin, DefaultStartPos)

		kz_chat(id, "%L", id, "KZ_START")
	}
	else if (g_bZoneStartAvailable)
	{
		if (!g_bStartZoneCached)
			CacheStartZone()
		if (g_bStartZoneCached)
		{
			set_pev(id, pev_velocity, Float:{0.0, 0.0, 0.0})
			set_pev(id, pev_origin, g_flStartZoneCenter)
			kz_chat(id, "%L", id, "KZ_START")
		}
		else
		{
			kz_chat(id, "%L", id, "KZ_NO_START")
			CmdRespawn(id)
		}
	}
	else
	{	
		kz_chat(id, "%L", id, "KZ_NO_START")
		CmdRespawn(id)
    }

	return PLUGIN_HANDLED
}

public setStart(id)
{
	if (! (get_user_flags( id ) & KZ_LEVEL ))
	{
		kz_chat(id, "%L", id, "KZ_NO_ACCESS")
		return PLUGIN_HANDLED
	}
    
	new Float:origin[3]
	pev(id, pev_origin, origin)
	kz_set_start(g_szMapName, origin)
	AutoStart[id] = false;
	ColorChat(id, GREEN, "%s^x01 %L.", prefix, id, "KZ_SET_START")
	
	return PLUGIN_HANDLED
}

// ========= Respawn CT if dies ========

public Ham_CBasePlayer_Killed_Post(id) 
{
	if(get_pcvar_num(kz_respawn_ct) == 1)
	{
		if( cs_get_user_team(id) == CS_TEAM_CT )
		{
			set_pev(id, pev_deadflag, DEAD_RESPAWNABLE)
   			cs_set_user_deaths(id, 0)
			set_user_frags(id, 0)
		}
	}
}


// =============================  NightVision ================================================

public ToggleNVG(id) 
{

	if( get_pcvar_num(kz_nvg) == 0 || !is_user_alive(id))
		return PLUGIN_CONTINUE;
   
	if ( NightVisionUse[id] )
		StopNVG(id) 
	else 
		StartNVG(id) 

	return PLUGIN_HANDLED
}

public StartNVG(id) 
{
	emit_sound(id,CHAN_ITEM,"items/nvg_on.wav",1.0,ATTN_NORM,0,PITCH_NORM) 
	set_task(0.1,"RunNVG",id+111111,_,_,"b") 
	NightVisionUse[id] = true; 
   
	return PLUGIN_HANDLED
}

public StopNVG(id) 
{
	emit_sound(id,CHAN_ITEM,"items/nvg_off.wav",1.0,ATTN_NORM,0,PITCH_NORM) 
	remove_task(id+111111) 
	NightVisionUse[id] = false; 

	return PLUGIN_HANDLED
}


public RunNVG(taskid) 
{
	new id = taskid - 111111
  
	if (!is_user_alive(id)) return
   
	new origin[3] 
	get_user_origin(id,origin,3)
   
	new color[17];
	get_pcvar_string(kz_nvg_colors,color,16);
   
	new iRed[5], iGreen[7], iBlue[5]
	parse(color,iRed,4,iGreen ,6,iBlue,4)
   
	message_begin(MSG, SVC_TEMPENTITY, _, id)
	write_byte(TE_DLIGHT)
	write_coord(origin[0]) 
	write_coord(origin[1]) 
	write_coord(origin[2]) 
	write_byte(80)
	write_byte(str_to_num(iRed)) 
	write_byte(str_to_num(iGreen)) 
	write_byte(str_to_num(iBlue))
	write_byte(2)
	write_byte(0) 
	message_end()
}

// ============================ Hook ==============================================================

public give_hook(id)
{
	if (!(  get_user_flags( id ) & KZ_LEVEL ))
		return PLUGIN_HANDLED

	new szarg1[32], szarg2[8], bool:mode
	read_argv(1,szarg1,32)
	read_argv(2,szarg2,32)
	if(equal(szarg2,"on"))
		mode = true

	if (mode && !get_pcvar_num(kz_hook_enabled))
	{
		console_print(id, "[KZ] Hook is globally disabled (kz_hook_enabled 0).")
		return PLUGIN_HANDLED
	}
		
	if(equal(szarg1,"@ALL"))
	{
		new Alive[32], alivePlayers
		get_players(Alive, alivePlayers, "ach")
		for(new i;i<alivePlayers;i++)
		{
			new pid = Alive[i]
			canusehook[pid] = mode
			if(mode)
				ColorChat(pid, GREEN,  "%s^x01, %L.", prefix, pid, "KZ_HOOK")
		}
	}
	else
	{
		new pid = find_player("bl",szarg1);
		if(pid > 0)
		{
			canusehook[pid] = mode
			if(mode)
			{
				ColorChat(pid, GREEN, "%s^x01 %L.", prefix, pid, "KZ_HOOK")
			}
		}
	}
	
	return PLUGIN_HANDLED
}

public hook_on(id)
{
	if( !is_user_alive(id) )
		return PLUGIN_HANDLED

	if (!get_pcvar_num(kz_hook_enabled))
	{
		kz_chat(id, "%L", id, "KZ_HOOK_DISABLED")
		return PLUGIN_HANDLED
	}

	if (get_pcvar_num(kz_hook_require_finish) && !canusehook[id])
	{
		kz_chat(id, "%L", id, "KZ_HOOK_REQUIRED")
		return PLUGIN_HANDLED
	}

	if (IsPaused[id])
	{
		kz_chat(id, "%L", id, "KZ_HOOK_PAUSE")
		return PLUGIN_HANDLED
	}
	
	detect_cheat(id,"Hook")
	get_user_origin(id,hookorigin[id],3)
	ishooked[id] = true
	antihookcheat[id] = get_gametime()
	
	if (get_pcvar_num(kz_hook_sound) == 1)
	emit_sound(id,CHAN_STATIC,"weapons/xbow_hit2.wav",1.0,ATTN_NORM,0,PITCH_NORM)

	set_task(0.1,"hook_task",id,"",0,"ab")
	hook_task(id)
	
	return PLUGIN_HANDLED
}

public hook_off(id)
{
	remove_hook(id)
	
	return PLUGIN_HANDLED
}

public hook_task(id)
{
	if(!is_user_connected(id) || !is_user_alive(id) || !get_pcvar_num(kz_hook_enabled)
		|| (get_pcvar_num(kz_hook_require_finish) && !canusehook[id]))
	{
		remove_hook(id)
		return
	}
	
	remove_beam(id)
	draw_hook(id)
	
	new origin[3], Float:velocity[3]
	get_user_origin(id,origin)
	new distance = get_distance(hookorigin[id],origin)
	if (distance <= 0)
	{
		remove_hook(id)
		return
	}
	velocity[0] = (hookorigin[id][0] - origin[0]) * (2.0 * get_pcvar_num(kz_hook_speed) / distance)
	velocity[1] = (hookorigin[id][1] - origin[1]) * (2.0 * get_pcvar_num(kz_hook_speed) / distance)
	velocity[2] = (hookorigin[id][2] - origin[2]) * (2.0 * get_pcvar_num(kz_hook_speed) / distance)
		
	set_pev(id,pev_velocity,velocity)
}

public draw_hook(id)
{
	message_begin(MSG_BROADCAST,SVC_TEMPENTITY)
	write_byte(1)				// TE_BEAMENTPOINT
	write_short(id)				// entid
	write_coord(hookorigin[id][0])		// origin
	write_coord(hookorigin[id][1])		// origin
	write_coord(hookorigin[id][2])		// origin
	write_short(Sbeam)			// sprite index
	write_byte(0)				// start frame
	write_byte(0)				// framerate
	write_byte(random_num(1,100))		// life
	write_byte(random_num(1,20))		// width
	write_byte(random_num(1,0))		// noise					
	write_byte(random_num(1,255))		// r
	write_byte(random_num(1,255))		// g
	write_byte(random_num(1,255))		// b
	write_byte(random_num(1,500))		// brightness
	write_byte(random_num(1,200))		// speed
	message_end()
}

public remove_hook(id)
{
	if(task_exists(id))
		remove_task(id)
	remove_beam(id)
	ishooked[id] = false
}

public remove_beam(id)
{
	message_begin(MSG_BROADCAST,SVC_TEMPENTITY)
	write_byte(99) // TE_KILLBEAM
	write_short(id)
	message_end()
}


//============================ VIP In ScoreBoard =================================================

public MessageScoreAttrib( iMsgID, iDest, iReceiver )
{
	if( get_pcvar_num(kz_vip) )
	{
		new iPlayer = get_msg_arg_int( 1 )
		if( is_user_alive( iPlayer ) && ( get_user_flags( iPlayer ) & KZ_LEVEL ) )
		{
			set_msg_arg_int( 2, ARG_BYTE, SCOREATTRIB_VIP );
		}
	}
}

public EventStatusValue( const id )
{
			
	new szMessage[ 34 ], Target, aux
	get_user_aiming(id, Target, aux)
	if (is_user_alive(Target))
	{
		formatex( szMessage, 33, "1 %s: %%p2", get_user_flags( Target ) & KZ_LEVEL ? "VIP" : "Oyuncu" )
		message_begin( MSG, get_user_msgid( "StatusText" ) , _, id )
		write_byte( 0 )
		write_string( szMessage )
		message_end( )
	}
}

public detect_cheat(id,reason[])
{ 
	if(timer_started[id] && get_pcvar_num(kz_cheatdetect) == 1) 
	{
		timer_started[id] = false
		g_bRunValid[id] = false
		if (g_iForwardRunReset)
		{
			new iReturn
			ExecuteForward(g_iForwardRunReset, iReturn, id)
		}
		if(IsPaused[id])
		{
			set_pev(id, pev_flags, pev(id, pev_flags) & ~FL_FROZEN)
			IsPaused[id] = false
		}
		if (get_pcvar_num(kz_show_timer) > 0 && ShowTime[id] == 2)
			kz_showtime_roundtime(id, 0)
		ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_CHEAT_DETECT", reason)
	}
}
 
// =================================================================================================
// Cmds
// =================================================================================================

public CheckPoint(id)
{
	
	if( !is_user_alive( id ) )
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}
	
	if(get_pcvar_num(kz_checkpoints) == 0)
	{
		kz_chat(id, "%L", id, "KZ_CHECKPOINT_OFF")
		return PLUGIN_HANDLED
	}

	if( !( pev( id, pev_flags ) & FL_ONGROUND2 ) && !IsOnLadder(id))
	{
		kz_chat(id, "%L", id, "KZ_CHECKPOINT_AIR")
		return PLUGIN_HANDLED
	}
		
	if( IsPaused[id] )
	{
		kz_chat(id, "%L", id, "KZ_CHECKPOINT_PAUSE")
		return PLUGIN_HANDLED
	}
		
	pev(id, pev_origin, Checkpoints[id][g_bCpAlternate[id] ? 1 : 0])
	g_bCpAlternate[id] = !g_bCpAlternate[id]
	checknumbers[id]++

	kz_chat(id, "%L", id, "KZ_CHECKPOINT", checknumbers[id])

	return PLUGIN_HANDLED
}

public GoCheck(id) 
{
	if( !is_user_alive( id ) )
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}

	if( checknumbers[id] == 0  ) 
	{
		kz_chat(id, "%L", id, "KZ_NOT_ENOUGH_CHECKPOINTS")
		return PLUGIN_HANDLED
	}

	if( IsPaused[id] )
	{
		kz_chat(id, "%L", id, "KZ_TELEPORT_PAUSE")	
		return PLUGIN_HANDLED
	}
	
	set_pev( id, pev_velocity, Float:{0.0, 0.0, 0.0} );
	set_pev( id, pev_view_ofs, Float:{  0.0,   0.0,  12.0 } );
	set_pev( id, pev_flags, pev(id, pev_flags) | FL_DUCKING );
	set_pev( id, pev_fuser2, 0.0 );
	engfunc( EngFunc_SetSize, id, {-16.0, -16.0, -18.0 }, { 16.0, 16.0, 32.0 } );
	set_pev(id, pev_origin, Checkpoints[ id ][ !g_bCpAlternate[id] ] )
	gochecknumbers[id]++
	PkzMarkRunUnranked(id)
	
	kz_chat(id, "%L", id, "KZ_GOCHECK", gochecknumbers[id])

	return PLUGIN_HANDLED
}

public Stuck(id)
{
	if( !is_user_alive( id ) )
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}

	if( checknumbers[id] < 2 ) 
	{
		kz_chat(id, "%L", id, "KZ_NOT_ENOUGH_CHECKPOINTS")
		return PLUGIN_HANDLED
	}

	set_pev( id, pev_velocity, Float:{0.0, 0.0, 0.0} )
	set_pev( id, pev_view_ofs, Float:{  0.0,   0.0,  12.0 })
	set_pev( id, pev_flags, pev(id, pev_flags) | FL_DUCKING )
	set_pev( id, pev_fuser2, 0.0 )
	engfunc( EngFunc_SetSize, id, {-16.0, -16.0, -18.0 }, { 16.0, 16.0, 32.0 } )
	set_pev(id, pev_origin, Checkpoints[id][g_bCpAlternate[id]] )
	g_bCpAlternate[id] = !g_bCpAlternate[id];
	gochecknumbers[id]++
	PkzMarkRunUnranked(id)
	
	kz_chat(id, "%L", id, "KZ_GOCHECK", gochecknumbers[id])
	
	return PLUGIN_HANDLED;
}
 
// =================================================================================================
 
public reset_checkpoints(id) 
{
	new bool:bWasRunning = timer_started[id]
	checknumbers[id] = 0
	gochecknumbers[id] = 0
	timer_started[id] = false
	timer_time[id] = 0.0
	g_bRunValid[id] = false
	user_has_scout[id] = false
	if(IsPaused[id])
	{
		set_pev(id, pev_flags, pev(id, pev_flags) & ~FL_FROZEN)
		IsPaused[id] = false
	}
	if (get_pcvar_num(kz_show_timer) > 0 && ShowTime[id] == 2)
		kz_showtime_roundtime(id, 0)

	if (bWasRunning && g_iForwardRunReset)
	{
		new iReturn
		ExecuteForward(g_iForwardRunReset, iReturn, id)
	}

	return PLUGIN_HANDLED
}

//===== Invis =======

public cmdInvisible(id)
{

	gViewInvisible[id] = !gViewInvisible[id]
	if(gViewInvisible[id])
		kz_chat(id, "%L", id, "KZ_INVISIBLE_PLAYERS_ON")
	else
		kz_chat(id, "%L", id, "KZ_INVISIBLE_PLAYERS_OFF")

	return PLUGIN_HANDLED
}

public cmdWaterInvisible(id)
{
	if( !gWaterFound )
	{
		kz_chat(id, "%L", id, "KZ_INVISIBLE_NOWATER")
		return PLUGIN_HANDLED
	}
	
	gWaterInvisible[id] = !gWaterInvisible[id]
	if(gWaterInvisible[id])
		kz_chat(id, "%L", id, "KZ_INVISIBLE_WATER_ON")
	else
		kz_chat(id, "%L", id, "KZ_INVISIBLE_WATER_OFF")
		
	return PLUGIN_HANDLED
}

//======================Semiclip / Invis==========================

public FM_client_AddToFullPack_Post(es, e, ent, host, hostflags, player, pSet) 
{ 
	if( player )
	{
		if (get_pcvar_num(kz_semiclip) == 1)
		{
			if ( host != ent && get_orig_retval() && is_user_alive(host) ) 
    			{ 
				set_es(es, ES_Solid, SOLID_NOT)
				set_es(es, ES_RenderMode, kRenderTransAlpha)
				set_es(es, ES_RenderAmt, get_pcvar_num(kz_semiclip_transparency))
			} 
		}
		if(gMarkedInvisible[ent] && gViewInvisible[host])
		{
 		  	set_es(es, ES_RenderMode, kRenderTransTexture)
			set_es(es, ES_RenderAmt, 0)
			set_es(es, ES_Origin, { 999999999.0, 999999999.0, 999999999.0 } )
		}
	}
	else if( gWaterInvisible[host] && gWaterEntity[ent] )
	{
		set_es(es, ES_Effects, get_es( es, ES_Effects ) | EF_NODRAW )
	}
	
	return FMRES_IGNORED
} 

public Ham_CBasePlayer_PreThink_Post(id) 
{ 
	if( !is_user_alive(id) ) 
	{ 
		return 
	} 

	if (timer_started[id] && !IsPaused[id])
	{
		new Float:flLimit = PkzGetSpeedLimit(g_iCategory[id])
		if (flLimit > 0.0)
		{
			new Float:flVelocity[3]
			pev(id, pev_velocity, flVelocity)
			new Float:flSpeed = floatsqroot(flVelocity[0] * flVelocity[0] + flVelocity[1] * flVelocity[1])
			if (flSpeed > flLimit + 1.0)
			{
				PkzInvalidateRun(id, "KZ_CATEGORY_SPEED_VIOLATION")
				return
			}
		}
	}

	RefreshPlayersList() 

	if (get_pcvar_num(kz_semiclip) == 1)
	{
		for(new i = 0; i<g_iNum; i++) 
		{ 
			g_iPlayer = g_iPlayers[i] 
			if( id != g_iPlayer ) 
			{ 
				set_pev(g_iPlayer, pev_solid, SOLID_NOT) 
			} 
		} 
	}
} 

public client_PostThink(id) 
{ 
	if( !is_user_alive(id) ) 
		return

	RefreshPlayersList() 

	if (get_pcvar_num(kz_semiclip) == 1)
		for(new i = 0; i<g_iNum; i++) 
   		{ 
			g_iPlayer = g_iPlayers[i] 
			if( g_iPlayer != id ) 
				set_pev(g_iPlayer, pev_solid, SOLID_SLIDEBOX) 
   		} 
} 

public noclip(id)
{
	if(!is_user_alive(id))
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}
	new noclip = !get_user_noclip(id)
	set_user_noclip(id, noclip)
	if(IsPaused[id] && (get_pcvar_num(kz_noclip_pause) == 1))
	{
		if(noclip)
		{
			pev(id, pev_origin, NoclipPos[id])
			set_pev(id, pev_flags, pev(id, pev_flags) & ~FL_FROZEN)
		}
		else
		{
			set_pev(id, pev_origin, NoclipPos[id])
			set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN)
		}
	}
	else if(noclip)
		detect_cheat(id,"Noclip")
	kz_chat(id, "%L", id, "KZ_NOCLIP" , noclip ? "ON" : "OFF")
    
	return PLUGIN_HANDLED
}

public GodMode(id)
{
	if(!is_user_alive(id))
	{
		kz_chat(id, "%L", id, "KZ_NOT_ALIVE")
		return PLUGIN_HANDLED
	}	
	
	new godmode = !get_user_godmode(id)
	set_user_godmode(id, godmode)
	if(godmode)
		detect_cheat(id,"Godmode")
	kz_chat(id, "%L", id, "KZ_GODMODE" , godmode ? "ON" : "OFF")
	
	return PLUGIN_HANDLED
}
 
// =================================================================================================

stock kz_set_start(const map[], Float:origin[3])
{
	new realfile[128], tempfile[128], formatorigin[50]
	formatex(realfile, 127, "%s/%s", Kzdir, KZ_STARTFILE)
	formatex(tempfile, 127, "%s/%s", Kzdir, KZ_STARTFILE_TEMP)
	formatex(formatorigin, 49, "%f %f %f", origin[0], origin[1], origin[2])
	
	DefaultStartPos = origin
	DefaultStart = true
	
	new file = fopen(tempfile, "wt")
	new vault = fopen(realfile, "rt")
	
	new data[128], key[64]
	new bool:replaced = false
	
	while( !feof(vault) )
	{
		fgets(vault, data, 127)
		parse(data, key, 63)
		
		if( equal(key, map) && !replaced )
		{
			fprintf(file, "%s %s^n", map, formatorigin)
			
			replaced = true
		}
		else
		{
			fputs(file, data)
		}
	}
	
	if( !replaced )
	{
		fprintf(file, "%s %s^n", map, formatorigin)
	}
	
	fclose(file)
	fclose(vault)
	
	delete_file(realfile)
	while( !rename_file(tempfile, realfile, 1) ) {}
}

stock kz_showtime_roundtime(id, time)
{
	if( is_user_connected(id) )
	{
		message_begin(MSG, get_user_msgid( "RoundTime" ), _, id);
		write_short(time + 1);
		message_end();
	}
}

stock kz_chat(id, const message[], {Float,Sql,Result,_}:...)
{
	new cvar = get_pcvar_num(kz_chatorhud)
	if(cvar == 0)
		return PLUGIN_HANDLED
		
	new msg[180], final[192]
	if (cvar == 1 && chatorhud[id] == -1 || chatorhud[id] == 1)
	{
		vformat(msg, 179, message, 3)
		formatex(final, 191, "%s^x01 %s", prefix, msg)
		kz_remplace_colors(final, 191)
		ColorChat(id, GREEN, "%s", final)
	}
	else if( cvar ==  2 && chatorhud[id] == -1 || chatorhud[id] == 2)
	{
			vformat(msg, 179, message, 3)
			replace_all(msg, 191, "^x01", "")
			replace_all(msg, 191, "^x03", "")
			replace_all(msg, 191, "^x04", "")
			replace_all(msg, 191, ".", "")
			kz_hud_message(id, "%s", msg)
	}
	
	return 1
}

stock kz_print_config(id, const msg[])
{
	message_begin(MSG_ONE_UNRELIABLE, get_user_msgid("SayText"), _, id);
	write_byte(id);
	write_string(msg);
	message_end();
}

stock kz_remplace_colors(message[], len)
{
	replace_all(message, len, "!g", "^x04")
	replace_all(message, len, "!t", "^x03")
	replace_all(message, len, "!y", "^x01")
}

stock kz_hud_message(id, const message[], {Float,Sql,Result,_}:...)
{
	static msg[192], colors[12], r[4], g[4], b[4];
	vformat(msg, 191, message, 3);
	
	get_pcvar_string(kz_hud_color, colors, 11)
	parse(colors, r, 3, g, 3, b, 4)
	
	set_hudmessage(str_to_num(r), str_to_num(g), str_to_num(b), -1.0, 0.90, 0, 0.0, 2.0, 0.0, 1.0, -1);
	ShowSyncHudMsg(id, hud_message, msg);
}

stock kz_register_saycmd(const saycommand[], const function[], flags) 
{
	new temp[64]
	formatex(temp, 63, "say /%s", saycommand)
	register_clcmd(temp, function, flags)
	formatex(temp, 63, "say .%s", saycommand)
	register_clcmd(temp, function, flags)
	formatex(temp, 63, "say_team /%s", saycommand)
	register_clcmd(temp, function, flags)
	formatex(temp, 63, "say_team .%s", saycommand)
	register_clcmd(temp, function, flags)
}

stock get_configsdir(name[],len)
{
	return get_localinfo("amxx_configsdir",name,len);
}

#if defined USE_SQL
stock GetNewRank(id, type)
{
	new createinto[1001]
	
	new cData[2]
	cData[0] = id
	cData[1] = type
	
	formatex(createinto, 1000, "SELECT authid FROM `%s` WHERE mapname='%s' ORDER BY time LIMIT 15", type == PRO_TOP ? "kz_pro15" : "kz_nub15", g_szMapName)
	SQL_ThreadQuery(g_SqlTuple, "GetNewRank_QueryHandler", createinto, cData, 2)
}

stock kz_update_plrname(id)
{
	new createinto[1001], authid[64], name[32]
	PkzGetPlayerKeyOnly(id, authid, charsmax(authid))
	get_user_name(id, name, 31)
	
	replace_all(name, 31, "\", "")
	replace_all(name, 31, "`", "")
	replace_all(name, 31, "'", "")

	formatex(createinto, 1000, "UPDATE `kz_pro15` SET name='%s' WHERE authid='%s'", name, authid)
	SQL_ThreadQuery(g_SqlTuple, "QueryHandle", createinto)
	formatex(createinto, 1000, "UPDATE `kz_nub15` SET name='%s' WHERE authid='%s'", name, authid)
	SQL_ThreadQuery(g_SqlTuple, "QueryHandle", createinto)
	return 1
}
#endif

public FwdSpawnWeaponbox( iEntity )
{
	if(get_pcvar_num(kz_remove_drops) == 1)
	{
		set_pev( iEntity, pev_flags, FL_KILLME )
		dllfunc( DLLFunc_Think, iEntity )
	}
	
	return HAM_IGNORED
}

public FwdHamDoorSpawn( iEntity )
{
	static const szNull[ ] = "common/null.wav";
	
	new Float:flDamage;
	pev( iEntity, pev_dmg, flDamage );
	
	if( flDamage < -999.0 ) {
		set_pev( iEntity, pev_noise1, szNull );
		set_pev( iEntity, pev_noise2, szNull );
		set_pev( iEntity, pev_noise3, szNull );
		
		if( !HealsOnMap )
			HealsOnMap = true
	}
}

public FwdHamPlayerSpawn( id )
{

	if( !is_user_alive( id ) )
		return;

	if(firstspawn[id])
	{
		ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_WELCOME")
		ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_COMMAND_HELP")

		if(get_pcvar_num(kz_checkpoints) == 0)
			ColorChat(id, GREEN,  "%s^x01 %L", id, "KZ_CHECKPOINT_OFF", prefix)


		if(Verif(id,1) && get_pcvar_num(kz_save_pos) == 1)
			savepos_menu(id)
		else if(get_pcvar_num(kz_spawn_mainmenu) == 1)
			kz_menu (id)
	}
	firstspawn[id] = false
	
		
	if( !user_has_weapon(id,CSW_KNIFE) )
		give_item( id,"weapon_knife" )

	if( HealsOnMap )
		set_user_health(id, 50175)
		
	if( IsPaused[id] )
	{
		set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN)
		set_pev(id, pev_origin, PauseOrigin[id])
	}
	
	if(get_pcvar_num(kz_use_radio) == 0)
	{
		#define XO_PLAYER				5
		#define	m_iRadiosLeft			192
		set_pdata_int(id, m_iRadiosLeft, 0, XO_PLAYER)
	}
}

public GroundWeapon_Touch(iWeapon, id)
{
	if( is_user_alive(id) && timer_started[id] && get_pcvar_num(kz_pick_weapons) == 0 )
		return HAM_SUPERCEDE

	return HAM_IGNORED
}
 
 
 
// ==================================Save positions=================================================
 
public SavePos(id)
{
	if(get_pcvar_num(kz_save_pos) == 0)
	{
		kz_chat(id, "%L", id, "KZ_SAVEPOS_DISABLED")
		return PLUGIN_HANDLED
	}
		
	if( !( pev( id, pev_flags ) & FL_ONGROUND2  ) )
	{
		kz_chat(id, "%L", id, "KZ_NOT_ON_GROUND")
		
		return PLUGIN_HANDLED
	}
	
	if(!timer_started[id])
	{
		kz_chat(id, "%L", id, "KZ_TIMER_NOT_STARTED")
		return PLUGIN_HANDLED
	}
	
	if(Verif(id,1))
	{
		ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_SAVEPOS_ALREADY")
		savepos_menu(id)
		return PLUGIN_HANDLED
	}
	
	if(get_user_noclip(id))
	{
		ColorChat(id, GREEN, "%s^x01 %L", prefix, id, "KZ_SAVEPOS_NOCLIP")
		return PLUGIN_HANDLED
	}
	
	new Float:origin[3], scout
	pev(id, pev_origin, origin)
	new Float:Time,check,gocheck 
	if(IsPaused[id])
	{
		Time = g_pausetime[id]
		Pause(id)
	}
	else
		Time=get_gametime() - timer_time[id]
	check=checknumbers[id]
	gocheck=gochecknumbers[id]
	ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_SAVEPOS")
	if (user_has_scout[id])
		scout=1
	else
		scout=0
	kz_savepos(id, Time, check, gocheck, origin, scout)
	reset_checkpoints(id)
	
	return PLUGIN_HANDLED
}

public GoPos(id)
{
	remove_hook(id)
	set_user_godmode(id, 0)
	set_user_noclip(id, 0)
	if(Verif(id,0))
	{
		set_pev(id, pev_velocity, Float:{0.0, 0.0, 0.0})
		set_pev(id, pev_flags, pev(id, pev_flags) | FL_DUCKING )
		set_pev(id, pev_origin, SavedOrigins[id] )
	}
	
	checknumbers[id]=SavedChecks[id]
	gochecknumbers[id]=SavedGoChecks[id]+((get_pcvar_num(kz_save_pos_gochecks)>0) ? 1 : 0)
	CheckPoint(id)
	CheckPoint(id)
	strip_user_weapons(id)
	give_item(id,"weapon_usp")
	give_item(id,"weapon_knife")
	if(SavedScout[id])
	{
		give_item(id, "weapon_scout")
		user_has_scout[id] = true
	}
	timer_time[id]=get_gametime()-SavedTime[id]
	timer_started[id]=true
	Pause(id)
	
}

public Verif(id, action)
{
	new realfile[128], tempfile[128], authid[64], szAuthId[64], map[64]
	new bool:exist = false
	get_mapname(map, 63)
	PkzGetPlayerKey(id, authid, charsmax(authid), szAuthId, charsmax(szAuthId))
	formatex(realfile, 127, "%s/%s.ini", SavePosDir, map)
	formatex(tempfile, 127, "%s/temp.ini", SavePosDir)
	
	if( !file_exists(realfile) )
		return 0

	new file = fopen(tempfile, "wt")
	new vault = fopen(realfile, "rt")
	new data[220], sid[64], time[25], checks[5], gochecks[5], x[25], y[25], z[25], scout[5]
	while( !feof(vault) )
	{
		fgets(vault, data, charsmax(data))
		parse(data, sid, 63, time, 24,  checks, 4, gochecks, 4, x, 24,  y, 24, z, 24, scout, 4)
		
		if( equal(sid, authid) && !exist) // ma aflu in fisier?
		{
			if(action == 1)
				fputs(file, data)
			exist= true 
			SavedChecks[id] = str_to_num(checks)
			SavedGoChecks[id] = str_to_num(gochecks)
			SavedTime[id] = str_to_float(time)
			SavedOrigins[id][0]=str_to_num(x)
			SavedOrigins[id][1]=str_to_num(y)
			SavedOrigins[id][2]=str_to_num(z)
			SavedScout[id] = str_to_num(scout)
		}
		else
		{
			fputs(file, data) 
		}
	}

	fclose(file)
	fclose(vault)
	
	delete_file(realfile)
	if(file_size(tempfile) == 0)
		delete_file(tempfile)
	else	
		while( !rename_file(tempfile, realfile, 1) ) {}
	
	
	if(!exist)
		return 0
	
	return 1
}
public kz_savepos (id, Float:time, checkpoints, gochecks, Float:origin[3], scout)
{
	new realfile[128], formatorigin[192], map[64], authid[64], szAuthId[64]
	get_mapname(map, 63)
	PkzGetPlayerKey(id, authid, charsmax(authid), szAuthId, charsmax(szAuthId))
	formatex(realfile, 127, "%s/%s.ini", SavePosDir, map)
	formatex(formatorigin, charsmax(formatorigin), "%s %f %d %d %d %d %d %d", authid, time, checkpoints, gochecks, origin[0], origin[1], origin[2], scout)
	write_file(realfile, formatorigin) // La sfarsit adaug datele mele
}
 
// =================================================================================================
// Events / Forwards
// =================================================================================================
 
//=================================================================================================
 
public client_disconnected(id)
{
	checknumbers[id] = 0
	gochecknumbers[id] = 0
	antihookcheat[id] = 0.0
	chatorhud[id] = -1
	timer_started[id] = false
	ShowTime[id] = get_pcvar_num(kz_show_timer)
	firstspawn[id] = true
	NightVisionUse[id] = false
	IsPaused[id] = false
	WasPaused[id] = false
	user_has_scout[id] = false
	g_iCategory[id] = PkzCalcCategoryIndex(true, false, false, 6)
	g_iPkzFpsIndex[id] = 6
	g_bRunValid[id] = false
	g_bRecordPending[id] = false
	g_bInsideStartZone[id] = false
	g_szPendingRunType[id][0] = 0
	g_szTopRunType[id][0] = 0
	g_szPlayerKey[id][0] = 0
	g_szPlayerAuthId[id][0] = 0
	g_bPkzModBHOP[id] = true
	g_bPkzModDJ[id] = false
	g_bPkzModLG[id] = false
	g_bPkzPrevJump[id] = false
	g_iPkzJumpCount[id] = 0
	remove_hook(id)
	canusehook[id] = false
}

public client_putinserver(id)
{
	checknumbers[id] = 0
	gochecknumbers[id] = 0
	antihookcheat[id] = 0.0
	chatorhud[id] = -1
	timer_started[id] = false
	ShowTime[id] = get_pcvar_num(kz_show_timer)
	firstspawn[id] = true
	NightVisionUse[id] = false
	IsPaused[id] = false
	WasPaused[id] = false
	user_has_scout[id] = false
	g_iCategory[id] = PkzCalcCategoryIndex(true, false, false, 6)
	g_iPkzFpsIndex[id] = 6
	g_bRunValid[id] = false
	g_bRecordPending[id] = false
	g_bInsideStartZone[id] = false
	g_szPendingRunType[id][0] = 0
	g_szTopRunType[id][0] = 0
	PkzRefreshPlayerIdentity(id)
	PkzSetDefaultMods(id)
	g_bPkzPrevJump[id] = false
	g_iPkzJumpCount[id] = 0
	remove_hook(id)
	canusehook[id] = false
	if (!is_user_bot(id))
		set_task(1.0, "PkzApplyCategoryTask", id)
}

public client_authorized(id)
{
	PkzRefreshPlayerIdentity(id)
}

public client_infochanged(id)
{
	if (is_user_connected(id))
		PkzRefreshPlayerIdentity(id)
}

public PkzApplyCategoryTask(id)
{
	if (is_user_connected(id) && !is_user_bot(id))
		PkzApplyCategory(id)
}

public PkzPlayerPreThink(id)
{
	if (!is_user_alive(id) || is_user_bot(id))
		return FMRES_IGNORED

	if (!get_pcvar_num(g_pPkzModEnabled))
		return FMRES_IGNORED

	new iFlags = pev(id, pev_flags)
	new iButtons = pev(id, pev_button)

	// Jump count reset on ground
	if (iFlags & FL_ONGROUND)
	{
		g_iPkzJumpCount[id] = 0
	}
	else if (g_bPkzModDJ[id])
	{
		new bool:bJumpPressed = (iButtons & IN_JUMP) ? true : false
		new bool:bNewJump = bJumpPressed && !g_bPkzPrevJump[id]

		if (bNewJump && g_iPkzJumpCount[id] < 1)
		{
			g_iPkzJumpCount[id]++
			static Float:flVelocity[3]
			pev(id, pev_velocity, flVelocity)
			flVelocity[2] = 265.0
			set_pev(id, pev_velocity, flVelocity)
		}
	}

	g_bPkzPrevJump[id] = (iButtons & IN_JUMP) ? true : false

	// Low gravity
	if (g_bPkzModLG[id])
		set_pev(id, pev_gravity, 400.0 / 800.0)
	else
		set_pev(id, pev_gravity, 1.0)

	return FMRES_IGNORED
}

public PkzPlayerJump(id)
{
	if (!is_user_alive(id) || is_user_bot(id) || !get_pcvar_num(g_pPkzModEnabled))
		return

	static iBhopStyle
	iBhopStyle = get_pcvar_num(g_pPkzModBhopStyle)

	if (!iBhopStyle)
	{
		static iOldButtons
		iOldButtons = pev(id, pev_oldbuttons)
		if (g_bPkzModBHOP[id] && (iOldButtons & IN_JUMP) && (pev(id, pev_flags) & FL_ONGROUND))
		{
			iOldButtons &= ~IN_JUMP
			set_pev(id, pev_oldbuttons, iOldButtons)
			set_pev(id, pev_gaitsequence, 6)
			set_pev(id, pev_frame, 0.0)
			return
		}
		return
	}

	if (pev(id, pev_waterlevel) >= 2)
		return

	static iFlags
	iFlags = pev(id, pev_flags)
	if (!(iFlags & FL_ONGROUND))
		return

	static iOldButtons
	iOldButtons = pev(id, pev_oldbuttons)
	if (!g_bPkzModBHOP[id] && (iOldButtons & IN_JUMP))
		return

	// Prevent engine jump speed clipping
	set_pev(id, pev_oldbuttons, iOldButtons | IN_JUMP)

	static Float:fVelocity[3]
	pev(id, pev_velocity, fVelocity)

	if (iBhopStyle == 1)
	{
		static Float:fMaxScaledSpeed
		pev(id, pev_maxspeed, fMaxScaledSpeed)
		if (fMaxScaledSpeed > 0.0)
		{
			fMaxScaledSpeed *= 1.7
			static Float:fSpeed
			fSpeed = floatsqroot(fVelocity[0] * fVelocity[0] + fVelocity[1] * fVelocity[1] + fVelocity[2] * fVelocity[2])
			if (fSpeed > fMaxScaledSpeed)
			{
				static Float:fFraction
				fFraction = (fMaxScaledSpeed / fSpeed) * 0.65
				fVelocity[0] *= fFraction
				fVelocity[1] *= fFraction
				fVelocity[2] *= fFraction
			}
		}
	}

	fVelocity[2] = 268.328157
	set_pev(id, pev_velocity, fVelocity)
	set_pev(id, pev_gaitsequence, 6)
	set_pev(id, pev_frame, 0.0)
}

public PkzHamTakeDamage(id, ent, idattacker, Float:damage, damagebits)
{
	if (damagebits != DMG_FALL)
		return HAM_IGNORED

	damage *= get_pcvar_float(g_pPkzModFallDamage)
	SetHamParamFloat(4, damage)
	return HAM_HANDLED
}

public PkzUpdateClientData(id, sendweapons, cd_handle)
{
	return FMRES_IGNORED
}
 
// =================================================================================================
// Menu
// =================================================================================================


public kz_menu(id)
{
	return kz_menu_page(id, 0)
}

stock kz_menu_page(id, iPage)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	new szPrefix[32];
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))

	new title[96];
	formatex(title, charsmax(title), "\y%s Main Menu\w", szPrefix)
	new menu = menu_create(title, "MenuHandler")  

	new szItem[128], szCatName[48]

	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_START")
	AddMainMenuItem(menu, szPrefix, szItem, "start")
	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_RESET")
	AddMainMenuItem(menu, szPrefix, szItem, "reset")

	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_MODS_SIMPLE")
		AddMainMenuItem(menu, szPrefix, szItem, "simple")
		formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_FPS_SIMPLE")
		AddMainMenuItem(menu, szPrefix, szItem, "simple")
	}
	else
	{
		PkzGetCategoryName(g_iCategory[id], szCatName, charsmax(szCatName))
		formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_MODS", szCatName)
		AddMainMenuItem(menu, szPrefix, szItem, "mod")

		formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_FPS", PkzGetFpsLimit(g_iCategory[id]))
		AddMainMenuItem(menu, szPrefix, szItem, "fps")
	}

	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_REPLAY")
	AddMainMenuItem(menu, szPrefix, szItem, "replay")
	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_MARKET")
	AddMainMenuItem(menu, szPrefix, szItem, "market")
	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_TOP15")
	AddMainMenuItem(menu, szPrefix, szItem, "top15")

	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_CHECKPOINT", checknumbers[id])
	AddMainMenuItem(menu, szPrefix, szItem, "cp")

	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_TELEPORT", gochecknumbers[id])
	AddMainMenuItem(menu, szPrefix, szItem, "gc")

	new szPauseStatus[16]
	formatex(szPauseStatus, charsmax(szPauseStatus), IsPaused[id] ? "\y[%L]" : "\r[%L]", id, "KZ_MOD_ON", id, "KZ_MOD_OFF")
	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_PAUSE", szPauseStatus)
	AddMainMenuItem(menu, szPrefix, szItem, "pause")

	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_SETTINGS")
	AddMainMenuItem(menu, szPrefix, szItem, "settings")
	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_SPEC")
	AddMainMenuItem(menu, szPrefix, szItem, "ct")
	formatex(szItem, charsmax(szItem), "%L", id, "KZ_MAIN_SAVEPOS")
	AddMainMenuItem(menu, szPrefix, szItem, "savepos")
	
	PkzMenuSetNavigation(menu, PKZ_MENU_NAV_EXIT)
	PkzMenuDisplaySafe(id, menu, iPage)
	return PLUGIN_HANDLED 
}

stock AddMainMenuItem(menu, const szPrefix[], const szText[], const szInfo[])
{
	new szItem[160]
	formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, szText)
	menu_additem(menu, szItem, szInfo)
}

public MenuHandler(id , menu, item)
{
	if (item < 0) {
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}

	new szInfo[24], szName[64], iAccess, iCallback
	menu_item_getinfo(menu, item, iAccess, szInfo, charsmax(szInfo), szName, charsmax(szName), iCallback)
	menu_destroy(menu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (equal(szInfo, "start")) {
		goStart(id)
		kz_menu(id)
	}
	else if (equal(szInfo, "reset")) {
		reset_checkpoints(id)
		kz_menu(id)
	}
	else if (equal(szInfo, "mod")) {
		PkzModMenu(id)
	}
	else if (equal(szInfo, "fps")) {
		PkzFPSMenu(id)
	}
	else if (equal(szInfo, "replay")) {
		client_cmd(id, "say /bot")
	}
	else if (equal(szInfo, "category")) {
		client_cmd(id, "say /mod")
	}
	else if (equal(szInfo, "market")) {
		client_cmd(id, "say /market")
	}
	else if (equal(szInfo, "simple")) {
		kz_chat(id, "%L", id, "KZ_SIMPLE_MODE_ACTIVE")
		kz_menu(id)
	}
	else if (equal(szInfo, "cp")) {
		CheckPoint(id)
		kz_menu_page(id, 1)
	}
	else if (equal(szInfo, "gc")) {
		GoCheck(id)
		kz_menu_page(id, 1)
	}
	else if (equal(szInfo, "pause")) {
		Pause(id)
		kz_menu_page(id, 1)
	}
	else if (equal(szInfo, "settings")) {
		SettingsMenu(id)
	}
	else if (equal(szInfo, "top15")) {
		top15menu(id)
	}
	else if (equal(szInfo, "ct")) {
		ct(id)
		kz_menu(id)
	}
	else if (equal(szInfo, "savepos")) {
		SavePos(id)
	}

	return PLUGIN_HANDLED
}

public SettingsMenu(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	new szPrefix[32];
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))
	
	new title[64];
	formatex(title, 63, "\y%s Settings Menu\w", szPrefix)
	new menu = menu_create(title, "SettingsMenuHandler")
	
	new msginvis[96], msgwaterinvis[96], roundtimer[96], hudtimer[96], notimer[96]
	formatex(msginvis, charsmax(msginvis), "\y%s\w Players - %s", szPrefix, gViewInvisible[id] ? "\yHIDDEN" : "\rVISIBLE" )
	formatex(msgwaterinvis, charsmax(msgwaterinvis), "\y%s\w Water - %s", szPrefix, gWaterInvisible[id] ? "\yHIDDEN" : "\rVISIBLE" )
	formatex(roundtimer, charsmax(roundtimer), "\y%s\w Round Time %s", szPrefix, ShowTime[id] == 2 ? "\y x" : "" )
	formatex(hudtimer, charsmax(hudtimer), "\y%s\w HUD Time %s", szPrefix, ShowTime[id] == 1 ? "\y x" : "" )
	formatex(notimer, charsmax(notimer), "\y%s\w Hide Timer %s", szPrefix, ShowTime[id] == 0 ? "\y x" : "" )
	
	menu_additem( menu, msginvis, "1" )
	menu_additem( menu, msgwaterinvis, "2" )
	menu_additem( menu, roundtimer, "3" )
	menu_additem( menu, hudtimer, "4" )
	menu_additem( menu, notimer, "5" )
	
	new szItem[96]
	formatex(szItem, charsmax(szItem), "\y%s\w Top 15 Menu", szPrefix)
	menu_additem( menu, szItem, "6" )
	
	PkzMenuSetNavigation(menu, PKZ_MENU_NAV_MAIN)
	PkzMenuDisplaySafe(id, menu, 0)
	return PLUGIN_HANDLED
}

public SettingsMenuHandler(id, menu, item)
{
	if (item < 0) {
		menu_destroy(menu)
		if (item == MENU_EXIT && is_user_connected(id))
			kz_menu(id)
		return PLUGIN_HANDLED
	}
	menu_destroy(menu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	switch(item) {
		case 0: {
			cmdInvisible(id)
			SettingsMenu(id)
		}
		case 1: {
			cmdWaterInvisible(id)
			SettingsMenu(id)
		}
		case 2: {
			ShowTime[id] = 2
			SettingsMenu(id)
		}
		case 3: {
			ShowTime[id] = 1
			SettingsMenu(id)
			if (timer_started[id])
				kz_showtime_roundtime(id, 0)
		}
		case 4: {
			ShowTime[id] = 0
			SettingsMenu(id)
			if (timer_started[id])
				kz_showtime_roundtime(id, 0)
		}
		case 5: {
			top15menu(id)
		}
	}
	return PLUGIN_HANDLED
}

public InvisMenu(id)
{
	return SettingsMenu(id)
}

public InvisMenuHandler(id, menu, item)
{
	return PLUGIN_HANDLED
}

public ShowTimer_Menu(id)
{
	return SettingsMenu(id)
}

public TimerHandler(id, menu, item)
{
	return PLUGIN_HANDLED
}

public savepos_menu(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	new szPrefix[32], szTitle[96], szItem[96]
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))
	formatex(szTitle, charsmax(szTitle), "\y%s\w Save Position", szPrefix)
	new menu = menu_create(szTitle, "SavePosHandler")
	formatex(szItem, charsmax(szItem), "\y%s\w Load Previous Run", szPrefix)
	menu_additem(menu, szItem, "1")
	formatex(szItem, charsmax(szItem), "\y%s\w Start New Run", szPrefix)
	menu_additem(menu, szItem, "2")
	PkzMenuSetNavigation(menu, PKZ_MENU_NAV_MAIN)
	PkzMenuDisplaySafe(id, menu, 0)
	return PLUGIN_HANDLED 
}

public SavePosHandler(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		if (item == MENU_EXIT && is_user_connected(id))
			kz_menu(id)
		return PLUGIN_HANDLED
	}
	menu_destroy(menu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	switch(item) 
	{
		case 0:
		{
			GoPos(id)
		}
		case 1:
		{
			Verif(id,0)
		}
	}
	return PLUGIN_HANDLED
}

public top15menu(id)
{
	return Top15CategoryMenu(id)
}

public top15handler(id, menu, item)
{
	if(item == MENU_EXIT)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	#if defined USE_SQL
	switch(item)
	{
		case 0:
		{
			ProTop_show(id)
		}
		case 1:
		{
			NoobTop_show(id)
		}
		case 2:
		{
			kz_showhtml_motd(id, PRO_RECORDS, "")
		}
		case 3:
		{
			kz_showhtml_motd(id, PLAYERS_RANKING, "")
		}
		case 4:
		{
			kz_showhtml_motd(id, LAST_PRO10, "")
		}
		case 5:
		{
			kz_showhtml_motd(id, MAPS_STATISTIC, "")
		}
		case 6:
		{
			kz_menu(id)
		}
	}
	#else
	switch(item)
	{
		case 0:
		{
			ProTop_show(id)
		}
		case 1:
		{
			NoobTop_show(id)
		}
		case 2:
		{
			SettingsMenu(id)
		}
	}
	#endif
	
	return PLUGIN_HANDLED;
}

// =================================================================================================

// 
// Timersystem
// =================================================================================================
public fwdUse(ent, id)
{
	if( !ent || id > 32 )
	{
		return HAM_IGNORED;
	}
	
	if( !is_user_alive(id) )
	{
		return HAM_IGNORED;
	}

	if ((g_bZoneStartAvailable && g_bZoneFinishAvailable) || is_user_bot(id))
	{
		return HAM_IGNORED;
	}

	
	new name[32]
	get_user_name(id, name, 31)
	
	new szTarget[ 32 ];
	pev(ent, pev_target, szTarget, 31);
	
	if( TrieKeyExists( g_tStarts, szTarget ) )
	{

		if ( get_gametime() - antihookcheat[id] < 3.0 )
		{	
			kz_hud_message( id, "%L", id, "KZ_HOOK_PROTECTION" );
			return PLUGIN_HANDLED
		}

		if(Verif(id,1))
		{
			ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_SAVEPOS_SAVED")
			savepos_menu(id)
			return HAM_IGNORED
		}
		
		if ( reset_checkpoints(id) && !timer_started[id]  )
		{
			start_climb(id)
			new wpn=get_user_weapon(id)
			for(new i = 0; i < 8; i++)
				if( user_has_weapon(id, other_weapons[i])  )
				{
					strip_user_weapons(id)
					give_item(id,"weapon_knife")
					give_item(id,"weapon_usp")
					set_pdata_int(id, 382, 24, 5)
					if(wpn==CSW_SCOUT)
					{
						user_has_scout[id]=true
						give_item(id,"weapon_scout")
					}
					else
						user_has_scout[id]=false
				}

			if( get_user_health(id) < 100 )
				set_user_health(id, 100)

			pev(id, pev_origin, SavedStart[id])
			if(get_pcvar_num(kz_save_autostart) == 1)
				AutoStart[id] = true;

			if( !DefaultStart )
			{
				kz_set_start(g_szMapName, SavedStart[id])
				ColorChat(id, GREEN,  "%s^x01 %L", prefix, id, "KZ_SET_START")
			}

			remove_hook(id)
		}
		
	}
	
	if( TrieKeyExists( g_tStops, szTarget ) )
	{
		if( timer_started[id] )
		{
			if(get_user_noclip(id))
				return PLUGIN_HANDLED
				
			finish_climb(id)

		}
		else
			kz_hud_message(id, "%L", id, "KZ_TIMER_NOT_STARTED")

		}
	return HAM_IGNORED
}

public start_climb(id)
{
	if (g_bRecordPending[id])
	{
		kz_chat(id, "%L", id, "KZ_RECORD_PENDING")
		return
	}

	kz_chat(id, "%L", id, "KZ_START_CLIMB")

	if (get_pcvar_num(kz_reload_weapons) == 1)
	{
		strip_user_weapons(id)
		give_item(id,"weapon_knife")
		give_item(id,"weapon_usp") 
	}

	if (ShowTime[id] == 2)
		kz_showtime_roundtime(id, 0)
	set_pev(id, pev_gravity, 1.0);
	set_pev(id, pev_movetype, MOVETYPE_WALK)
	set_user_godmode(id, 0)
	reset_checkpoints(id)
	IsPaused[id] = false
	g_bRunValid[id] = true
	g_iFpsViolations[id] = 0
	timer_started[id] = true
	timer_time[id] = get_gametime()

	if (g_iForwardRunStarted)
	{
		new iReturn
		ExecuteForward(g_iForwardRunStarted, iReturn, id, g_iCategory[id], g_szPendingRunType[id])
	}
}

public finish_climb(id)
{
	if (!is_user_alive (id))
	{
		return;
	}

	new Float:time = get_gametime() - timer_time[id]
	new iTimeMs = floatround(time * 1000.0)
	show_finish_message(id, time)
	timer_started[id] = false
	if (get_pcvar_num(kz_show_timer) > 0 && ShowTime[id] == 2)
		kz_showtime_roundtime(id, 0)

	client_cmd(0, "spk buttons/bell1")

	new szRunType[8]
	if (g_bRunValid[id] && gochecknumbers[id] == 0 && !user_has_scout[id])
		copy(szRunType, 7, "pro")
	else
		copy(szRunType, 7, "noob")

	PkzRecordFinish(id, iTimeMs, szRunType)
	GrantHookPrize(id)

	g_bRunValid[id] = false
	user_has_scout[id] = false
}

stock GrantHookPrize(id)
{
	if (!get_pcvar_num(kz_hook_prize) || canusehook[id])
		return

	canusehook[id] = true
	if (get_pcvar_num(kz_hook_enabled))
		ColorChat(id, GREEN, "%s^x01 %L.", prefix, id, "KZ_HOOK")
}

public show_finish_message(id, Float:kreedztime)
{
	new name[32]
	new imin,isec,ims, wpn
	if(user_has_scout[id])
		wpn=CSW_SCOUT
	else
		wpn=get_user_weapon( id ) 
	get_user_name(id, name, 31)
	imin = floatround(kreedztime / 60.0, floatround_floor)
	isec = floatround(kreedztime - imin * 60.0,floatround_floor)
	ims = floatround( ( kreedztime - ( imin * 60.0 + isec ) ) * 100.0, floatround_floor )
	
	ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x04 %02i:%02i.%02i ^x03(^x01 CP: ^x04%d^x03 | ^x01 GC: ^x04%d^x03 | ^x01 %L: ^x04%s^x03) ^x01!", prefix, name, LANG_PLAYER, "KZ_FINISH_MSG", imin, isec, ims, checknumbers[id], gochecknumbers[id], LANG_PLAYER, "KZ_WEAPON", g_weaponsnames[wpn])
}

//==========================================================
#if defined USE_SQL
public Set_QueryHandler(iFailState, Handle:hQuery, szError[], iErrnum, cData[], iSize, Float:fQueueTime)
{
	new id = cData[0]
	new style = cData[1]
	if( iFailState != TQUERY_SUCCESS )
	{
		log_amx("[KZ] TOP15 SQL: SQL Error #%d - %s", iErrnum, szError)
		ColorChat(0, GREEN,  "%s^x01 %F", prefix, LANG_PLAYER, "KZ_TOP15_SQL_ERROR")
	}
	
	server_print("[KZ] Server Geting Info of SQL Server")
	
	new createinto[1001]
	new x1[16], x2[4], x3[5], x4[5]
	parse(cData[2], x1, 15, x2, 3, x3, 4, x4, 4)

	new dia[64], steam[64], name[32], ip[15], country[3], checkpoints[32], gochecks[32]
	new Float:newtime = str_to_float(x1)
	new iMin, iSec, iMs, server[64]
	get_pcvar_string(kz_sql_name, server, 63)
	get_time("%Y%m%d%H%M%S", dia, sizeof dia - 1) 
	PkzGetPlayerKeyOnly(id, steam, charsmax(steam))
	get_user_name(id, name, sizeof name - 1)
	get_user_ip (id, ip, sizeof ip - 1, 1)
	geoip_code2_ex( ip, country)
	
	replace_all(name, 31, "\", "")
	replace_all(name, 31, "`", "")
	replace_all(name, 31, "'", "")
	

	if( SQL_NumResults(hQuery) == 0 )
	{
		formatex(checkpoints, 31, ", '%d'", str_to_num(x3))
		formatex(gochecks, 31, ", '%d'", str_to_num(x4))
		formatex( createinto, sizeof createinto - 1, "INSERT INTO `%s` VALUES('%s', '%s','%s','%s','%f','%s','%s','%s'%s%s)", style == PRO_TOP ? "kz_pro15" : "kz_nub15", g_szMapName, steam, country, name, newtime, dia, g_weaponsnames[str_to_num(x2)], server, style == PRO_TOP ? "" : checkpoints, style == PRO_TOP ? "" : gochecks)
		SQL_ThreadQuery(g_SqlTuple, "QueryHandle", createinto)
		GetNewRank(id, style)
	}
	else
	{
		new Float:oldtime, Float:thetime
		SQL_ReadResult(hQuery, 0, oldtime)
		
		if(newtime < oldtime)
		{
			thetime = oldtime - newtime
			iMin = floatround(thetime / 60.0, floatround_floor)
			iSec = floatround(thetime - iMin * 60.0,floatround_floor)
			iMs = floatround( ( thetime - ( iMin * 60.0 + iSec ) ) * 100.0, floatround_floor )
			ColorChat(id, GREEN,  "%s^x01 %L^x03 %02i:%02i.%02i^x01 in ^x03%s", prefix, id, "KZ_IMPROVE", iMin, iSec, iMs, style == PRO_TOP ? "Pro 15" : "Noob 15")
			formatex(checkpoints, 31, ", checkpoints='%d'", str_to_num(x3))
			formatex(gochecks, 31, ", gocheck='%d'", str_to_num(x4))
			formatex(createinto, sizeof createinto - 1, "UPDATE `%s` SET time='%f', weapon='%s', date='%s', server='%s'%s%s WHERE authid='%s' AND mapname='%s'", style == PRO_TOP ? "kz_pro15" : "kz_nub15", newtime, g_weaponsnames[str_to_num(x2)],  dia, server, style == PRO_TOP ? "" : gochecks, style == PRO_TOP ? "" : checkpoints, steam, g_szMapName)
	
			SQL_ThreadQuery(g_SqlTuple, "QueryHandle", createinto )
			GetNewRank(id, style)
		}
		else
		{
			thetime = newtime - oldtime
			iMin = floatround(thetime / 60.0, floatround_floor)
			iSec = floatround(thetime - iMin * 60.0,floatround_floor)
			iMs = floatround( ( thetime - ( iMin * 60.0 + iSec ) ) * 100.0, floatround_floor )
			ColorChat(id, GREEN,  "%s^x01 %L^x03 %02i:%02i.%02i ^x01in ^x03%s", prefix, id, "KZ_SLOWER", iMin, iSec, iMs, style == PRO_TOP ? "Pro 15" : "Noob 15")
		}
	}
	
	return PLUGIN_CONTINUE
	
}

public GetNewRank_QueryHandler(iFailState, Handle:hQuery, szError[], iErrnum, cData[], iSize, Float:fQueueTime)
{
	new id = cData[0]
	if( iFailState != TQUERY_SUCCESS )
	{
		return log_amx("TOP15 SQL: SQL Error #%d - %s", iErrnum, szError)
	}
	
	new steam[64], authid[64], namez[32], i = 0
	PkzGetPlayerKeyOnly(id, steam, charsmax(steam))
	get_user_name(id, namez, 31)
	
	while( SQL_MoreResults(hQuery) )
	{
		i++
		SQL_ReadResult(hQuery, 0, authid, charsmax(authid))
		if( equal(authid, steam) )
		{
			ColorChat(0, GREEN,  "%s^x03 %s^x01 %L ^x03%d^x01 in^x03 %s^x01",prefix, namez, LANG_PLAYER, "KZ_PLACE", i, cData[1] == PRO_TOP ? "Pro 15" : "Noob 15");
			break;
		}
		SQL_NextRow(hQuery)
	}
	
	return PLUGIN_CONTINUE	
}

public ProTop_show(id)
{
	kz_showhtml_motd(id, PRO_TOP, g_szMapName)
		
	return PLUGIN_HANDLED
}

public NoobTop_show(id)
{

	kz_showhtml_motd(id, NUB_TOP, g_szMapName)
	
	return PLUGIN_HANDLED
}

public ProRecs_show(id)
{
	kz_showhtml_motd(id, PRO_RECORDS, g_szMapName)

	return PLUGIN_HANDLED
}

stock kz_showhtml_motd(id, type, const map[])
{
	new buffer[1001], namebuffer[64], filepath[96]
	get_pcvar_string(kz_sql_files, filepath, 95)
	new authid[64]
	PkzGetPlayerKeyOnly(id, authid, charsmax(authid))
	
	switch( type )
	{
		case PRO_TOP:
		{
			formatex(namebuffer, 63, "Pro 15 of %s", equal(map, "") ? "All Maps" : map)
			formatex(buffer, 1000, "<html><head><meta http-equiv=^"Refresh^" content=^"0;url=http://%s/pro15.php?map=%s^"></head><body><p>LOADING...</p></body></html>", filepath, map)
		}
		case NUB_TOP:
		{
			formatex(namebuffer, 63, "Noob 15 of %s", equal(map, "") ? "All Maps" : map)
			formatex(buffer, 1000, "<html><head><meta http-equiv=^"Refresh^" content=^"0;url=http://%s/nub15.php?map=%s^"></head><body><p>LOADING...</p></body></html>", filepath, map)
		}
		case PRO_RECORDS:
		{
			formatex(namebuffer, 63, "ProRecords and Rank")
			formatex(buffer, 1000, "<html><head><meta http-equiv=^"Refresh^" content=^"0;url=http://%s/player.php?authid=%s^"></head><body><p>LOADING...</p></body></html>", filepath, authid)
		}
		case PLAYERS_RANKING:
		{
			formatex(namebuffer, 63, "Players Ranking")
			formatex(buffer, 1000, "<html><head><meta http-equiv=^"Refresh^" content=^"0;url=http://%s/players.php^"></head><body><p>LOADING...</p></body></html>", filepath, authid)
		}
		case LAST_PRO10:
		{
			formatex(namebuffer, 63, "Last 10 Pro Entries")
			formatex(buffer, 1000, "<html><head><meta http-equiv=^"Refresh^" content=^"0;url=http://%s/lastpro.php^"></head><body><p>LOADING...</p></body></html>", filepath)
		}
		case MAPS_STATISTIC:
		{
			formatex(namebuffer, 63, "Maps Statistic")
			formatex(buffer, 1000, "<html><head><meta http-equiv=^"Refresh^" content=^"0;url=http://%s/map.php^"></head><body><p>LOADING...</p></body></html>", filepath)
		}
	}
	
	show_motd(id, buffer, namebuffer)
}
#else
public ProTop_update(id, Float:time)
{
	new authid[64], name[32], thetime[32], Float: slower, Float: faster, Float:protiempo
	get_user_name(id, name, 31);
	PkzGetPlayerKeyOnly(id, authid, charsmax(authid));
	get_time(" %d/%m/%Y ", thetime, 31);
	new bool:Is_in_pro15
	Is_in_pro15 = false

	for(new i = 0; i < 15; i++)
	{
		if( (equali(Pro_Names[i], name) && (get_pcvar_num(kz_top15_authid) == 0)) || (equali(Pro_AuthIDS[i], authid) && (get_pcvar_num(kz_top15_authid) == 1)) )
		{
			Is_in_pro15 = true
			slower = time - Pro_Times[i]
			faster = Pro_Times[i] - time
			protiempo = Pro_Times[i]
		}
	}
	
	for (new i = 0; i < 15; i++)
	{	
		if( time < Pro_Times[i])
		{
			new pos = i
			if ( get_pcvar_num(kz_top15_authid) == 0 )
				while( !equal(Pro_Names[pos], name) && pos < 15 )
				{
					pos++;
				}
			else if ( get_pcvar_num(kz_top15_authid) == 1)
				while( !equal(Pro_AuthIDS[pos], authid) && pos < 15 )
				{
					pos++;
				}
			
			for (new j = pos; j > i; j--)
			{
				formatex(Pro_AuthIDS[j], 31, Pro_AuthIDS[j-1]);
				formatex(Pro_Names[j], 31, Pro_Names[j-1]);
				formatex(Pro_Date[j], 31, Pro_Date[j-1])
				Pro_Times[j] = Pro_Times[j-1];
			}
			
			formatex(Pro_AuthIDS[i], 31, authid);
			formatex(Pro_Names[i], 31, name);
			formatex(Pro_Date[i], 31, thetime)
			Pro_Times[i] = time
			
			save_pro15()
			
			if( Is_in_pro15 )
			{

				if( time < protiempo )
				{
					new min, Float:sec;
					min = floatround(faster, floatround_floor)/60;
					sec = faster - (60*min);
					ColorChat(id, GREEN,  "%s^x01 %L ^x03%02d:%s%.2f^x01", prefix, id, "KZ_IMPROVE", min, sec < 10 ? "0" : "", sec);
					
					if( (i + 1) == 1)
					{
						client_cmd(0, "spk woop");
						ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 1^x01 in ^x04Pro 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE");
					}
					else
					{
						client_cmd(0, "spk buttons/bell1");
						ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 %d^x01 in ^x04Pro 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE", (i+1));
					}
				}	
			}
			else
			{
				if( (i + 1) == 1)
				{
					client_cmd(0, "spk woop");
					ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 1^x01 in ^x04Pro 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE");
				}
				else
				{
					client_cmd(0, "spk buttons/bell1");
					ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 %d^x01 in ^x04Pro 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE", (i+1));
				}
			}
			
			return;
		}

		if( (equali(Pro_Names[i], name) && (get_pcvar_num(kz_top15_authid) == 0)) || (equali(Pro_AuthIDS[i], authid) && (get_pcvar_num(kz_top15_authid) == 1)) )
		{
			if( time > protiempo )
			{
				new min, Float:sec;
				min = floatround(slower, floatround_floor)/60;
				sec = slower - (60*min);
				ColorChat(id, GREEN,  "%s^x01 %L ^x03%02d:%s%.2f^x01", prefix, id, "KZ_SLOWER", min, sec < 10 ? "0" : "", sec);
				return;
			}
		}
		
	}
}

public save_pro15()
{
	new profile[128]
	formatex(profile, 127, "%s/pro_%s.cfg", Topdir, g_szMapName)
	
	if( file_exists(profile) )
	{
		delete_file(profile)
	}
   
	new Data[256];
	new f = fopen(profile, "at")
	
	for(new i = 0; i < 15; i++)
	{
		formatex(Data, 255, "^"%.2f^"   ^"%s^"   ^"%s^"   ^"%s^"^n", Pro_Times[i], Pro_AuthIDS[i], Pro_Names[i], Pro_Date[i])
		fputs(f, Data)
	}
	fclose(f);
}

public read_pro15()
{
	new profile[128], prodata[256]
	formatex(profile, 127, "%s/pro_%s.cfg", Topdir, g_szMapName)
	
	new f = fopen(profile, "rt" )
	new i = 0
	while( !feof(f) && i < 16)
	{
		fgets(f, prodata, 255)
		new totime[25]
		parse(prodata, totime, 24, Pro_AuthIDS[i], 31, Pro_Names[i], 31, Pro_Date[i], 31)
		Pro_Times[i] = str_to_float(totime)
		i++;
	}
	fclose(f)
}

//==================================================================================================

public NoobTop_update(id, Float:time, checkpoints, gochecks) 
{
	new authid[64], name[32], thetime[32], wpn, Float: slower, Float: faster, Float:noobtiempo
	get_user_name(id, name, 31);
	PkzGetPlayerKeyOnly(id, authid, charsmax(authid));
	get_time(" %d/%m/%Y ", thetime, 31);
	new bool:Is_in_noob15
	Is_in_noob15 = false
	if(user_has_scout[id])
		wpn=CSW_SCOUT
	else
		wpn=get_user_weapon(id)
	
	for(new i = 0; i < 15; i++)
	{
		if( (equali(Noob_Names[i], name) && (get_pcvar_num(kz_top15_authid) == 0)) || (equali(Noob_AuthIDS[i], authid) && (get_pcvar_num(kz_top15_authid) == 1)) )
		{
			Is_in_noob15 = true
			slower = time - Noob_Tiempos[i];
			faster = Noob_Tiempos[i] - time;
			noobtiempo = Noob_Tiempos[i]
		}
	}
	
	for (new i = 0; i < 15; i++)
	{
		if( time < Noob_Tiempos[i])
		{
			new pos = i
			
			if ( get_pcvar_num(kz_top15_authid) == 0 )
				while( !equal(Noob_Names[pos], name) && pos < 15 )
				{
					pos++;
				}
			else if ( get_pcvar_num(kz_top15_authid) == 1)
				while( !equal(Noob_AuthIDS[pos], authid) && pos < 15 )
				{
					pos++;
				}
			
			for (new j = pos; j > i; j--)
			{
				formatex(Noob_AuthIDS[j], 31, Noob_AuthIDS[j-1])
				formatex(Noob_Names[j], 31, Noob_Names[j-1])
				formatex(Noob_Date[j], 31, Noob_Date[j-1])
				formatex(Noob_Weapon[j], 31, Noob_Weapon[j-1])
				Noob_Tiempos[j] = Noob_Tiempos[j-1]
				Noob_CheckPoints[j] = Noob_CheckPoints[j-1]
				Noob_GoChecks[j] = Noob_GoChecks[j-1]	
			}
			
			formatex(Noob_AuthIDS[i], 31, authid);
			formatex(Noob_Names[i], 31, name);
			formatex(Noob_Date[i], 31, thetime)
			formatex(Noob_Weapon[i], 31, g_weaponsnames[wpn])
			Noob_Tiempos[i] = time
			Noob_CheckPoints[i] = checkpoints
			Noob_GoChecks[i] = gochecks
			
			save_Noob15()
			
			if( Is_in_noob15 )
			{

				if( time < noobtiempo )
				{
					new min, Float:sec;
					min = floatround(faster, floatround_floor)/60;
					sec = faster - (60*min);
					ColorChat(id, GREEN,  "%s^x01 %L ^x03%02d:%s%.2f^x01", prefix, id, "KZ_IMPROVE", min, sec < 10 ? "0" : "", sec);
					
					if( (i + 1) == 1)
					{
						client_cmd(0, "spk woop");
						ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 1^x01 in ^x04Noob 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE");
					}
					else
					{
						client_cmd(0, "spk buttons/bell1");
						ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 %d^x01 in ^x04Noob 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE", (i+1));
					}
				}	
			}
			else
			{
				if( (i + 1) == 1)
				{
					client_cmd(0, "spk woop");
					ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 1^x01 in ^x04Noob 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE");
				}
				else
				{
					client_cmd(0, "spk buttons/bell1");
					ColorChat(0, GREEN,  "%s^x01^x03 %s^x01 %L^x03 %d^x01 in ^x04Noob 15^x01", prefix, name, LANG_PLAYER, "KZ_PLACE", (i+1));
				}
			}
			return;
		}

		if( (equali(Noob_Names[i], name) && (get_pcvar_num(kz_top15_authid) == 0)) || (equali(Noob_AuthIDS[i], authid) && (get_pcvar_num(kz_top15_authid) == 1)) )
		{
			if( time > noobtiempo )
			{
				
				new min, Float:sec;
				min = floatround(slower, floatround_floor)/60;
				sec = slower - (60*min);
				ColorChat(id, GREEN,  "%s^x01 %L ^x03%02d:%s%.2f^x01", prefix, id, "KZ_SLOWER", min, sec < 10 ? "0" : "", sec);
				return;
			}
		}
		
	}
}

public save_Noob15()
{
	new profile[128]
	formatex(profile, 127, "%s/Noob_%s.cfg", Topdir, g_szMapName)
	
	if( file_exists(profile) )
	{
		delete_file(profile)
	}
   
	new Data[256];
	new f = fopen(profile, "at")
	
	for(new i = 0; i < 15; i++)
	{
		formatex(Data, 255, "^"%.2f^"   ^"%s^"   ^"%s^"   ^"%i^"   ^"%i^"   ^"%s^"  ^"%s^" ^n", Noob_Tiempos[i], Noob_AuthIDS[i], Noob_Names[i], Noob_CheckPoints[i], Noob_GoChecks[i],Noob_Date[i],Noob_Weapon[i])
		fputs(f, Data)
	}
	fclose(f);
}

public read_Noob15()
{
	new profile[128], prodata[256]
	formatex(profile, 127, "%s/Noob_%s.cfg", Topdir, g_szMapName)
	
	new f = fopen(profile, "rt" )
	new i = 0
	while( !feof(f) && i < 16)
	{
		fgets(f, prodata, 255)
		new totime[25], checks[5], gochecks[5]
		parse(prodata, totime, 24, Noob_AuthIDS[i], 31, Noob_Names[i], 31,  checks, 4, gochecks, 4, Noob_Date[i], 31, Noob_Weapon[i], 31)
		Noob_Tiempos[i] = str_to_float(totime)
		Noob_CheckPoints[i] = str_to_num(checks)
		Noob_GoChecks[i] = str_to_num(gochecks)
		i++;
	}
	fclose(f)
}

public ProTop_show(id)
{		
	new  buffer[2048], len, name[32]

	len = formatex(buffer, 2047, "<body bgcolor=#3399FF><table width=100%% cellpadding=2 cellspacing=0 border=0>")
	len += formatex(buffer[len], 2047-len, "<tr  align=center bgcolor=#0052FF><th width=5%%> # <th width=45%% align=center> Player <th  width=30%%> Time <th width=20%%> Date ")
		
	for (new i = 0; i < 10; i++) 
	{	
		name = Pro_Names[i]
		
		if( Pro_Times[i] > 9999999.0 ) 
		{
			len += formatex(buffer[len], 2047-len, "<tr align=center%s><td> %d <td align=center> %s <td> %s <td> %s", ((i%2)==0) ? " bgcolor=#5DA5FF" : " bgcolor=#3399FF", (i+1), "", "", "")
		}

		else
		{
			new minutos, Float:segundos
			minutos = floatround(Pro_Times[i], floatround_floor)/60
			segundos = Pro_Times[i] - (60*minutos)

			len += formatex(buffer[len], 2047-len, "<tr align=center%s><td> %d <td align=center> %s <td> <b>%02d:%s%.2f <td> %s", ((i%2)==0) ? " bgcolor=#5DA5FF" : " bgcolor=#3399FF", (i+1), Pro_Names[i], minutos, segundos < 10 ? "0" : "", segundos, Pro_Date[i])

		}
	}

	len += formatex(buffer[len], 2047-len, "</table></body>")
	len += formatex(buffer[len], 2047-len, "<tr><Center><b><BR>Plugin created by nucLeaR")
		
	show_motd(id, buffer, "Pro10 Climbers")

	return PLUGIN_HANDLED
}

public NoobTop_show(id)
{
	new buffer[2048], name[32], len

	len = formatex(buffer, 2047, "<body bgcolor=#3399FF><table width=100%% cellpadding=2 cellspacing=0 border=0>")
	len += formatex(buffer[len], 2047-len, "<tr  align=center bgcolor=#0052FF><th width=5%%> # <th width=35%% align=center> Player <th  width=20%%> Time  <th width=10%%> CPs <th width=10%%> TPs <th width=10%%> Date")
		
	for (new i = 0; i < 10; i++) 
	{		
		if( Noob_Tiempos[i] > 9999999.0 ) 
		{
			len += formatex(buffer[len], 2047-len, "<tr align=center%s><td> %d <td align=center> %s <td> %s <td> %s <td> %s <td> %s", ((i%2)==0) ? " bgcolor=#5DA5FF" : " bgcolor=#3399FF", (i+1), "", "", "", "", "")
		}

		else 
		{
			name = Noob_Names[i]
			new minutos, Float:segundos
			minutos = floatround(Noob_Tiempos[i], floatround_floor)/60
			segundos = Noob_Tiempos[i] - (60*minutos)
			
			len += formatex(buffer[len], 2047-len, "<tr align=center%s><td> %d <td align=center> %s%s <td> <b>%02d:%s%.2f <td> %d <td> %d <td> %s", ((i%2)==0) ? " bgcolor=#5DA5FF" : " bgcolor=#3399FF", (i+1), Noob_Names[i], equal(Noob_Weapon[i],"scout") ? "(scout)" : "", minutos, segundos < 10 ? "0" : "", segundos, Noob_CheckPoints[i], Noob_GoChecks[i], Noob_Date[i], Noob_Weapon[i])
		}
	}
	
	len += formatex(buffer[len], 2047-len, "</table></body>")
	len += formatex(buffer[len], 2047-len, "<tr><Center><b><BR>Plugin created by nucLeaR")
		
	show_motd(id, buffer, "Noob10 Climbers")

	return PLUGIN_HANDLED
}
#endif

// =================================================================================================
// ProKreedz 3.0 kategori, zone ve yerel kayt API'si
// =================================================================================================

public native_get_user_category(iPlugin, iParams)
{
	new id = get_param(1)
	if (get_pcvar_num(g_pPkzSimpleMode))
		return 0
	return (1 <= id <= 32) ? g_iCategory[id] : PkzCalcCategoryIndex(false, false, false, 1)
}

public native_is_user_running(iPlugin, iParams)
{
	new id = get_param(1)
	return (1 <= id <= 32 && timer_started[id]) ? 1 : 0
}

public native_get_simple_mode(iPlugin, iParams)
{
	return get_pcvar_num(g_pPkzSimpleMode) ? 1 : 0
}

public native_is_user_paused(iPlugin, iParams)
{
	new id = get_param(1)
	return (1 <= id <= 32 && IsPaused[id]) ? 1 : 0
}

public native_get_category_slug(iPlugin, iParams)
{
	new iCategory = get_param(1)
	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		set_string(2, "simple", get_param(3))
		return 1
	}
	if (iCategory < 0 || iCategory >= PKZ_CATEGORY_COUNT)
		iCategory = PkzCalcCategoryIndex(true, false, false, 3)

	new szSlug[32]
	PkzGetCategorySlug(iCategory, szSlug, charsmax(szSlug))
	set_string(2, szSlug, get_param(3))
	return 1
}

public native_get_category_name(iPlugin, iParams)
{
	new iCategory = get_param(1)
	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		set_string(2, "Simple", get_param(3))
		return 1
	}
	if (iCategory < 0 || iCategory >= PKZ_CATEGORY_COUNT)
		iCategory = PkzCalcCategoryIndex(true, false, false, 3)

	new szName[48]
	PkzGetCategoryName(iCategory, szName, charsmax(szName))
	set_string(2, szName, get_param(3))
	return 1
}

public native_get_user_mod(iPlugin, iParams)
{
	new id = get_param(1)
	new iModType = get_param(2)

	if (id < 1 || id > 32)
		return 0

	switch (iModType)
	{
		case PKZ_MOD_BHOP: return g_bPkzModBHOP[id] ? 1 : 0
		case PKZ_MOD_DOUBLEJUMP: return g_bPkzModDJ[id] ? 1 : 0
		case PKZ_MOD_LOWGRAV: return g_bPkzModLG[id] ? 1 : 0
	}
	return 0
}

public native_set_user_mod(iPlugin, iParams)
{
	new id = get_param(1)
	new iModType = get_param(2)
	new iEnabled = get_param(3)

	if (id < 1 || id > 32)
		return

	switch (iModType)
	{
		case PKZ_MOD_BHOP: g_bPkzModBHOP[id] = bool:iEnabled
		case PKZ_MOD_DOUBLEJUMP: g_bPkzModDJ[id] = bool:iEnabled
		case PKZ_MOD_LOWGRAV: g_bPkzModLG[id] = bool:iEnabled
	}

	PkzUpdateCategory(id)
}

public PkzModMenu(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		kz_chat(id, "%L", id, "KZ_SIMPLE_MODE_ACTIVE")
		return PLUGIN_HANDLED
	}

	new szPrefix[32]
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))

	new szCatName[48]
	PkzGetCategoryName(g_iCategory[id], szCatName, charsmax(szCatName))

	new szTitle[96], szItem[128], szLabel[96], szInfo[4]
	formatex(szTitle, charsmax(szTitle), "%L", id, "KZ_MOD_MENU_TITLE", szPrefix, szCatName)
	new iMenu = menu_create(szTitle, "PkzModMenuHandler")

	num_to_str(1, szInfo, charsmax(szInfo))
	formatex(szLabel, charsmax(szLabel), "%L", id, "KZ_MOD_BHOP", g_bPkzModBHOP[id] ? "On" : "Off")
	formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, szLabel)
	menu_additem(iMenu, szItem, szInfo)

	num_to_str(2, szInfo, charsmax(szInfo))
	formatex(szLabel, charsmax(szLabel), "%L", id, "KZ_MOD_DOUBLEJUMP", g_bPkzModDJ[id] ? "On" : "Off")
	formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, szLabel)
	menu_additem(iMenu, szItem, szInfo)

	num_to_str(3, szInfo, charsmax(szInfo))
	formatex(szLabel, charsmax(szLabel), "%L", id, "KZ_MOD_LOWGRAV", g_bPkzModLG[id] ? "On" : "Off")
	formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, szLabel)
	menu_additem(iMenu, szItem, szInfo)

	PkzMenuSetNavigation(iMenu, PKZ_MENU_NAV_MAIN)
	PkzMenuDisplaySafe(id, iMenu)
	return PLUGIN_HANDLED
}

public PkzModMenuHandler(id, iMenu, iItem)
{
	if (iItem < 0)
	{
		menu_destroy(iMenu)
		if (iItem == MENU_EXIT && is_user_connected(id))
			kz_menu(id)
		return PLUGIN_HANDLED
	}

	new szInfo[4], szName[64], iAccess, iCallback
	menu_item_getinfo(iMenu, iItem, iAccess, szInfo, charsmax(szInfo), szName, charsmax(szName), iCallback)
	new iKey = str_to_num(szInfo)
	menu_destroy(iMenu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	switch (iKey)
	{
		case 1: g_bPkzModBHOP[id] = !g_bPkzModBHOP[id]
		case 2: g_bPkzModDJ[id] = !g_bPkzModDJ[id]
		case 3: g_bPkzModLG[id] = !g_bPkzModLG[id]
	}

	PkzUpdateCategory(id)
	PkzModMenu(id)
	return PLUGIN_HANDLED
}

// FPS menu - shows only the 7 FPS options
public PkzFPSMenu(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		kz_chat(id, "%L", id, "KZ_SIMPLE_MODE_ACTIVE")
		return PLUGIN_HANDLED
	}

	new szPrefix[32]
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))

	new szTitle[96], szItem[96], szInfo[8]
	formatex(szTitle, charsmax(szTitle), "%L", id, "KZ_FPS_MENU_TITLE", szPrefix, PkzGetFpsLimit(g_iCategory[id]))
	new iMenu = menu_create(szTitle, "PkzFPSMenuHandler")

	for (new i = 0; i < PKZ_FPS_COUNT; i++)
	{
		num_to_str(i, szInfo, charsmax(szInfo))
		if (g_iPkzFpsIndex[id] == i)
		{
			new szSelected[64]
			formatex(szSelected, charsmax(szSelected), "%L", id, "KZ_FPS_SELECTED", g_szFpsName[i])
			formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, szSelected)
		}
		else
			formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, g_szFpsName[i])
		menu_additem(iMenu, szItem, szInfo)
	}

	PkzMenuSetNavigation(iMenu, PKZ_MENU_NAV_MAIN)
	PkzMenuDisplaySafe(id, iMenu)
	return PLUGIN_HANDLED
}

public PkzFPSMenuHandler(id, iMenu, iItem)
{
	if (iItem < 0)
	{
		menu_destroy(iMenu)
		if (iItem == MENU_EXIT && is_user_connected(id))
			return kz_menu(id)
		return PLUGIN_HANDLED
	}

	new szInfo[8], szName[64], iAccess, iCallback
	menu_item_getinfo(iMenu, iItem, iAccess, szInfo, charsmax(szInfo), szName, charsmax(szName), iCallback)
	new iFpsIdx = str_to_num(szInfo)
	menu_destroy(iMenu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (0 <= iFpsIdx && iFpsIdx < PKZ_FPS_COUNT)
	{
		g_iPkzFpsIndex[id] = iFpsIdx
		PkzUpdateCategory(id)
	}
	return PLUGIN_HANDLED
}

public CmdSimpleMode(id, iLevel, iCid)
{
	if (read_argc() < 2)
	{
		console_print(id, "[KZ] Usage: amx_simple <0|1>")
		return PLUGIN_HANDLED
	}

	new szArg[4]
	read_argv(1, szArg, charsmax(szArg))
	new iVal = str_to_num(szArg)
	set_pcvar_num(g_pPkzSimpleMode, iVal ? 1 : 0)
	log_amx("[ProKreedz] %n set simple mode to %d", id, iVal ? 1 : 0)
	console_print(id, "[KZ] Simple mode set to %s.", iVal ? "ON" : "OFF")

	for (new i = 1; i <= 32; i++)
	{
		if (is_user_connected(i))
			PkzUpdateCategory(i)
	}
	return PLUGIN_HANDLED
}

stock PkzSetDefaultMods(id)
{
	new szDefault[24]
	get_pcvar_string(g_pPkzModDefault, szDefault, charsmax(szDefault))

	g_bPkzModBHOP[id] = false
	g_bPkzModDJ[id] = false
	g_bPkzModLG[id] = false

	if (equali(szDefault, "bhop") || equali(szDefault, "autobunny"))
		g_bPkzModBHOP[id] = true
	else if (equali(szDefault, "doublejump") || equali(szDefault, "dj"))
		g_bPkzModDJ[id] = true
	else if (equali(szDefault, "lowgrav") || equali(szDefault, "lowgravity") || equali(szDefault, "lg"))
		g_bPkzModLG[id] = true
	else if (equali(szDefault, "bhop+dj") || equali(szDefault, "bhop_dj"))
	{
		g_bPkzModBHOP[id] = true
		g_bPkzModDJ[id] = true
	}
	else if (equali(szDefault, "bhop+lg") || equali(szDefault, "bhop_lg"))
	{
		g_bPkzModBHOP[id] = true
		g_bPkzModLG[id] = true
	}
	else if (equali(szDefault, "all"))
	{
		g_bPkzModBHOP[id] = true
		g_bPkzModDJ[id] = true
		g_bPkzModLG[id] = true
	}

	PkzUpdateCategory(id)
}

stock PkzUpdateCategory(id)
{
	new iNewCat
	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		g_bPkzModBHOP[id] = get_pcvar_num(g_pPkzSimpleBHOP) ? true : false
		g_bPkzModDJ[id] = get_pcvar_num(g_pPkzSimpleDJ) ? true : false
		g_bPkzModLG[id] = get_pcvar_num(g_pPkzSimpleLG) ? true : false
		iNewCat = 0
	}
	else
	{
		iNewCat = PkzCalcCategoryIndex(g_bPkzModBHOP[id], g_bPkzModDJ[id], g_bPkzModLG[id], g_iPkzFpsIndex[id])
	}
	if (iNewCat != g_iCategory[id])
	{
		if (timer_started[id])
			reset_checkpoints(id)
		g_iCategory[id] = iNewCat
		PkzApplyCategory(id)
		new szCatName[48]
		PkzGetCategoryName(g_iCategory[id], szCatName, charsmax(szCatName))
		kz_chat(id, "%L", id, "KZ_CATEGORY_SELECTED", szCatName)
	}
}

stock PkzApplyCategory(id)
{
	if (get_pcvar_num(g_pPkzSimpleMode))
	{
		client_cmd(id, "developer 1")
		client_cmd(id, "fps_override 1")
		client_cmd(id, "fps_max 2000")
		return
	}

	new iFps = PkzGetFpsLimit(g_iCategory[id])
	if (!iFps)
		return

	if (iFps > 100)
	{
		client_cmd(id, "developer 1")
		client_cmd(id, "fps_override 1")
	}
	else
	{
		client_cmd(id, "developer 0")
		client_cmd(id, "fps_override 0")
	}

	switch (iFps)
	{
		case 60: client_cmd(id, "fps_max 58")
		case 100: client_cmd(id, "fps_max 99")
		case 200: client_cmd(id, "fps_max 199")
		case 250: client_cmd(id, "fps_max 249")
		case 333: client_cmd(id, "fps_max 332")
		case 500: client_cmd(id, "fps_max 499")
		case 1000: client_cmd(id, "fps_max 1000")
	}
}

public native_get_player_key(iPlugin, iParams)
{
	new id = get_param(1)
	new iLength = get_param(3)
	if (id < 1 || id > 32 || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id) || iLength < 1)
	{
		set_string(2, "", iLength)
		return 0
	}

	new szKey[64]
	PkzGetPlayerKeyOnly(id, szKey, charsmax(szKey))
	set_string(2, szKey, iLength)
	return szKey[0] ? 1 : 0
}

public native_open_main_menu(iPlugin, iParams)
{
	new id = get_param(1)
	if (id < 1 || id > 32 || !is_user_connected(id))
		return 0

	kz_menu(id)
	return 1
}

public native_enter_spectator(iPlugin, iParams)
{
	new id = get_param(1)
	if (id < 1 || id > 32 || !is_user_connected(id) || IsPaused[id])
		return 0

	if (cs_get_user_team(id) != CS_TEAM_SPECTATOR)
		ct(id)

	return cs_get_user_team(id) == CS_TEAM_SPECTATOR ? 1 : 0
}

public PkzCmdStart(id, iUcHandle, iSeed)
{
	if (!is_user_alive(id))
		return FMRES_IGNORED

	pev(id, pev_velocity, g_flSurfFixStartVelocity[id])

	if (is_user_bot(id))
		return FMRES_IGNORED

	if (!timer_started[id] || IsPaused[id])
		return FMRES_IGNORED

	if (get_pcvar_num(g_pPkzSimpleMode))
		return FMRES_IGNORED

	new iLimit = PkzGetFpsLimit(g_iCategory[id])
	new iMsec = get_uc(iUcHandle, UC_Msec)
	if (iLimit > 0 && iMsec > 0)
	{
		new iFps = floatround(1000.0 / float(iMsec))
		if (iFps > iLimit + 2)
		{
			g_iFpsViolations[id]++
			if (g_iFpsViolations[id] >= 3)
				PkzInvalidateRun(id, "KZ_CATEGORY_FPS_VIOLATION")
		}
		else
		{
			g_iFpsViolations[id] = 0
		}
	}

	return FMRES_IGNORED
}

public PkzCmdEnd(id)
{
	if (!is_user_alive(id))
		return FMRES_IGNORED

	static Float:flVelocity[3], Float:flBaseVelocity[3]
	pev(id, pev_velocity, flVelocity)

	// trigger_push hizini gercek hareket sifirlanmasi gibi algilamamak icin ayir.
	if (!PkzSurfFixVectorZero(flVelocity))
	{
		pev(id, pev_basevelocity, flBaseVelocity)
		if (!PkzSurfFixVectorZero(flBaseVelocity))
		{
			flVelocity[0] = floatabs(flVelocity[0]) - floatabs(flBaseVelocity[0])
			flVelocity[1] = floatabs(flVelocity[1]) - floatabs(flBaseVelocity[1])
		}
	}

	if (!PkzSurfFixVectorZero(g_flSurfFixStartVelocity[id]) && PkzSurfFixVectorZero(flVelocity) && PkzSurfFixOnSlope(id))
	{
		static Float:flOrigin[3]
		new iHull = (pev(id, pev_flags) & FL_DUCKING) ? HULL_HEAD : HULL_HUMAN

		pev(id, pev_origin, flOrigin)
		flOrigin[2] += PKZ_SURF_FIX_UNSTUCK_HEIGHT

		if (PkzSurfFixHullVacant(flOrigin, iHull, id))
		{
			set_pev(id, pev_origin, flOrigin)
			set_pev(id, pev_velocity, g_flSurfFixStartVelocity[id])
		}
	}

	return FMRES_IGNORED
}

stock bool:PkzSurfFixVectorZero(const Float:flVector[3])
{
	return flVector[0] == 0.0 && flVector[1] == 0.0
}

stock bool:PkzSurfFixHullVacant(const Float:flOrigin[3], iHull, id)
{
	static iTrace
	engfunc(EngFunc_TraceHull, flOrigin, flOrigin, 0, iHull, id, iTrace)
	if (!get_tr2(iTrace, TR_StartSolid) || !get_tr2(iTrace, TR_AllSolid))
		return true

	return false
}

stock bool:PkzSurfFixOnSlope(id)
{
	static Float:flPlaneNormal[3], Float:flTraceEnd[3], Float:flOrigin[3]
	static Float:flRampAngle

	pev(id, pev_origin, flOrigin)

	flTraceEnd[0] = flOrigin[0]
	flTraceEnd[1] = flOrigin[1]
	flTraceEnd[2] = flOrigin[2] - PKZ_SURF_FIX_TRACE_HULL_HEIGHT

	new iHull = (pev(id, pev_flags) & FL_DUCKING) ? HULL_HEAD : HULL_HUMAN

	engfunc(EngFunc_TraceHull, flOrigin, flTraceEnd, IGNORE_MONSTERS | IGNORE_MISSILE, iHull, id, 0)
	get_tr2(0, TR_vecPlaneNormal, flPlaneNormal)

	flRampAngle = flPlaneNormal[2]
	return flRampAngle != 0.0 && flRampAngle != 1.0
}

stock PkzInvalidateRun(id, const szMessage[])
{
	if (!timer_started[id])
		return

	reset_checkpoints(id)
	kz_chat(id, "%L", id, szMessage)
}

stock PkzMarkRunUnranked(id)
{
	if (!timer_started[id] || !g_bRunValid[id])
		return

	g_bRunValid[id] = false
	if (g_iForwardRunReset)
	{
		new iReturn
		ExecuteForward(g_iForwardRunReset, iReturn, id)
	}
}

stock CacheStartZone()
{
	if (g_bStartZoneCached)
		return

	g_bStartZoneCached = false
	new szConfigDir[64], szPath[192]
	get_configsdir(szConfigDir, charsmax(szConfigDir))
	formatex(szPath, charsmax(szPath), "%s/prokreedz/zones/%s.ini", szConfigDir, g_szMapName)
	if (!file_exists(szPath))
		return

	new iFile = fopen(szPath, "rt")
	if (!iFile)
		return

	new szLine[256], szType[16], szVal[6][24]
	while (!feof(iFile))
	{
		fgets(iFile, szLine, charsmax(szLine))
		trim(szLine)
		if (!szLine[0] || szLine[0] == ';' || szLine[0] == '#')
			continue
		parse(szLine, szType, charsmax(szType), szVal[0], 23, szVal[1], 23, szVal[2], 23, szVal[3], 23, szVal[4], 23, szVal[5], 23)
		if (!equal(szType, "start"))
			continue
		new Float:flMins[3], Float:flMaxs[3]
		for (new i = 0; i < 3; i++)
		{
			flMins[i] = str_to_float(szVal[i])
			flMaxs[i] = str_to_float(szVal[i + 3])
		}
		for (new i = 0; i < 3; i++)
			g_flStartZoneCenter[i] = (flMins[i] + flMaxs[i]) * 0.5
		g_bStartZoneCached = true
		break
	}
	fclose(iFile)
}

public pkz_zones_ready(iHasStart, iHasFinish)
{
	g_bZoneStartAvailable = bool:iHasStart
	g_bZoneFinishAvailable = bool:iHasFinish
	if (iHasStart)
		CacheStartZone()
	server_print("[ProKreedz] Zone status: start=%d finish=%d", iHasStart, iHasFinish)
}

public pkz_zone_enter(id, iZoneType)
{
	if (!is_user_alive(id) || is_user_bot(id))
		return

	if (iZoneType == PKZ_ZONE_START)
	{
		g_bInsideStartZone[id] = true
		reset_checkpoints(id)
	}
	else if (iZoneType == PKZ_ZONE_FINISH && timer_started[id])
	{
		finish_climb(id)
	}
}

public pkz_zone_leave(id, iZoneType)
{
	if (iZoneType != PKZ_ZONE_START || !g_bInsideStartZone[id] || !is_user_alive(id) || is_user_bot(id))
		return

	g_bInsideStartZone[id] = false
	if (g_bZoneStartAvailable && g_bZoneFinishAvailable)
		start_climb(id)
}

public PkzStorageInit()
{
	g_bLocalDbReady = false
	copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: starting")

	if (!SQL_SetAffinity("sqlite"))
	{
		log_amx("[ProKreedz] SQLite driver could not be loaded")
		copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: driver unavailable")
		return
	}

	g_hLocalTuple = SQL_MakeDbTuple("", "", "", "prokreedz")
	new iErrorCode, szError[256]
	new Handle:hConnection = SQL_Connect(g_hLocalTuple, iErrorCode, szError, charsmax(szError))
	if (hConnection == Empty_Handle)
	{
		log_amx("[ProKreedz] SQLite connection error #%d: %s", iErrorCode, szError)
		formatex(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: connection error #%d", iErrorCode)
		return
	}

	if (!PkzExecRequired(hConnection,
		"CREATE TABLE IF NOT EXISTS kz_records (mapname TEXT NOT NULL, category TEXT NOT NULL, run_type TEXT NOT NULL DEFAULT 'pro', player_key TEXT NOT NULL, authid TEXT NOT NULL, country TEXT NOT NULL DEFAULT '--', name TEXT NOT NULL, time_ms INTEGER NOT NULL, recorded_at TEXT NOT NULL, weapon TEXT NOT NULL, server TEXT NOT NULL, PRIMARY KEY (mapname, category, run_type, player_key))",
		"SQLite table creation"))
	{
		SQL_FreeHandle(hConnection)
		copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: table error")
		return
	}

	// Migration-safe schema upkeep. These ALTERs are intentionally optional:
	// existing columns produce harmless duplicate-column errors which are ignored.
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN run_type TEXT NOT NULL DEFAULT 'pro'")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN player_key TEXT NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN authid TEXT NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN country TEXT NOT NULL DEFAULT '--'")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN name TEXT NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN time_ms INTEGER NOT NULL DEFAULT 0")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN recorded_at TEXT NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN weapon TEXT NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN server TEXT NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "CREATE UNIQUE INDEX IF NOT EXISTS uq_kz_records_identity ON kz_records (mapname, category, run_type, player_key)")
	PkzExecOptional(hConnection, "CREATE INDEX IF NOT EXISTS idx_kz_records_ranking ON kz_records (mapname, category, run_type, time_ms)")
	PkzExecOptional(hConnection, "CREATE INDEX IF NOT EXISTS idx_kz_records_player ON kz_records (authid, category)")

	SQL_FreeHandle(hConnection)
	g_bLocalDbReady = true
	copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: ready, MySQL mirror: disabled")
	server_print("[ProKreedz] SQLite category records ready (migration-safe)")

	if (get_pcvar_num(pkz_mysql_enabled))
		PkzMysqlInit()
}

stock PkzMysqlInit()
{
	g_bMysqlReady = false

	new szHost[64], szUser[64], szPass[64], szDb[64], szError[256], iErrorCode
	get_pcvar_string(pkz_mysql_host, szHost, charsmax(szHost))
	get_pcvar_string(pkz_mysql_user, szUser, charsmax(szUser))
	get_pcvar_string(pkz_mysql_pass, szPass, charsmax(szPass))
	get_pcvar_string(pkz_mysql_db, szDb, charsmax(szDb))
	if (!szHost[0] || !szDb[0] || !SQL_SetAffinity("mysql"))
	{
		log_amx("[ProKreedz] MySQL is enabled but connection settings are missing")
		copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: ready, MySQL mirror: missing settings")
		return
	}

	g_hMysqlTuple = SQL_MakeDbTuple(szHost, szUser, szPass, szDb)
	new Handle:hConnection = SQL_Connect(g_hMysqlTuple, iErrorCode, szError, charsmax(szError))
	if (hConnection == Empty_Handle)
	{
		log_amx("[ProKreedz] MySQL connection error #%d: %s", iErrorCode, szError)
		formatex(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: ready, MySQL mirror: connection error #%d", iErrorCode)
		return
	}

	if (!PkzExecRequired(hConnection,
		"CREATE TABLE IF NOT EXISTS kz_records (mapname VARCHAR(64) NOT NULL, category VARCHAR(64) NOT NULL, run_type VARCHAR(8) NOT NULL DEFAULT 'pro', player_key VARCHAR(64) NOT NULL, authid VARCHAR(64) NOT NULL, country VARCHAR(6) NOT NULL DEFAULT '--', name VARCHAR(64) NOT NULL, time_ms INT UNSIGNED NOT NULL, recorded_at DATETIME NOT NULL, weapon VARCHAR(64) NOT NULL, server VARCHAR(64) NOT NULL, PRIMARY KEY (mapname,category,run_type,player_key), KEY idx_kz_records_ranking (mapname,category,run_type,time_ms), KEY idx_kz_records_player (authid,category)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4",
		"MySQL table creation"))
	{
		SQL_FreeHandle(hConnection)
		copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: ready, MySQL mirror: table error")
		return
	}

	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN run_type VARCHAR(8) NOT NULL DEFAULT 'pro'")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN player_key VARCHAR(64) NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN authid VARCHAR(64) NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN country VARCHAR(6) NOT NULL DEFAULT '--'")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN name VARCHAR(64) NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN time_ms INT UNSIGNED NOT NULL DEFAULT 0")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN recorded_at DATETIME NOT NULL DEFAULT '1970-01-01 00:00:00'")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN weapon VARCHAR(64) NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD COLUMN server VARCHAR(64) NOT NULL DEFAULT ''")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD UNIQUE INDEX uq_kz_records_identity (mapname,category,run_type,player_key)")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD INDEX idx_kz_records_ranking (mapname,category,run_type,time_ms)")
	PkzExecOptional(hConnection, "ALTER TABLE kz_records ADD INDEX idx_kz_records_player (authid,category)")

	g_bMysqlReady = true
	copy(g_szDbStatus, charsmax(g_szDbStatus), "SQLite: ready, MySQL mirror: ready")
	server_print("[ProKreedz] MySQL category records mirror ready")
	SQL_FreeHandle(hConnection)
}

stock bool:PkzExecRequired(Handle:hConnection, const szQueryText[], const szContext[])
{
	new Handle:hQuery = SQL_PrepareQuery(hConnection, szQueryText)
	if (!SQL_Execute(hQuery))
	{
		new szError[256]
		SQL_QueryError(hQuery, szError, charsmax(szError))
		log_amx("[ProKreedz] %s error: %s", szContext, szError)
		SQL_FreeHandle(hQuery)
		return false
	}
	SQL_FreeHandle(hQuery)
	return true
}

stock PkzExecOptional(Handle:hConnection, const szQueryText[])
{
	new Handle:hQuery = SQL_PrepareQuery(hConnection, szQueryText)
	SQL_Execute(hQuery)
	SQL_FreeHandle(hQuery)
}

public PkzDbStatus(id, iLevel, iCid)
{
	if (id && !(get_user_flags(id) & iLevel))
	{
		console_print(id, "[ProKreedz] You have no access to this command.")
		return PLUGIN_HANDLED
	}

	console_print(id, "[ProKreedz] SQLite: %s", (g_bLocalDbReady && g_hLocalTuple != Empty_Handle) ? "ready" : "not ready")
	if (get_pcvar_num(pkz_mysql_enabled))
		console_print(id, "[ProKreedz] MySQL mirror: %s", (g_bMysqlReady && g_hMysqlTuple != Empty_Handle) ? "ready" : "enabled but not ready")
	else
		console_print(id, "[ProKreedz] MySQL mirror: disabled")

	console_print(id, "[ProKreedz] Status: %s", g_szDbStatus[0] ? g_szDbStatus : "not initialized")
	return PLUGIN_HANDLED
}

stock PkzGetPlayerKey(id, szKey[], iKeyLen, szAuthId[], iAuthLen)
{
	if (!g_szPlayerKey[id][0])
		PkzRefreshPlayerIdentity(id)

	copy(szKey, iKeyLen, g_szPlayerKey[id])
	copy(szAuthId, iAuthLen, g_szPlayerAuthId[id])
	PkzSqlClean(szKey, iKeyLen)
	PkzSqlClean(szAuthId, iAuthLen)
}

stock PkzGetPlayerKeyOnly(id, szKey[], iKeyLen)
{
	new szAuthId[64]
	PkzGetPlayerKey(id, szKey, iKeyLen, szAuthId, charsmax(szAuthId))
}

stock PkzRefreshPlayerIdentity(id)
{
	if (id < 1 || id > 32 || !is_user_connected(id) || is_user_bot(id))
		return

	new szAuthId[64], szKey[64]
	get_user_authid(id, szAuthId, charsmax(szAuthId))
	copy(g_szPlayerAuthId[id], charsmax(g_szPlayerAuthId[]), szAuthId)

	if (PkzIsStableAuthId(szAuthId))
	{
		formatex(szKey, charsmax(szKey), "steam:%s", szAuthId)
	}
	else
	{
		new szIp[32]
		get_user_ip(id, szIp, charsmax(szIp), 1)
		if (szIp[0])
		{
			formatex(szKey, charsmax(szKey), "ip:%s", szIp)
		}
		else
		{
			new szName[32]
			get_user_name(id, szName, charsmax(szName))
			strtolower(szName)
			replace_all(szName, charsmax(szName), " ", "_")
			formatex(szKey, charsmax(szKey), "name:%s", szName)
		}
	}

	PkzCleanIdentityKey(szKey, charsmax(szKey))
	PkzSqlClean(g_szPlayerAuthId[id], charsmax(g_szPlayerAuthId[]))
	copy(g_szPlayerKey[id], charsmax(g_szPlayerKey[]), szKey)
}

stock bool:PkzIsStableAuthId(const szAuthId[])
{
	if (!szAuthId[0]
		|| equal(szAuthId, "BOT")
		|| equal(szAuthId, "STEAM_ID_PENDING")
		|| equal(szAuthId, "STEAM_ID_LAN")
		|| equal(szAuthId, "VALVE_ID_LAN"))
	{
		return false
	}
	return true
}

stock PkzCleanIdentityKey(szText[], iLen)
{
	replace_all(szText, iLen, " ", "_")
	replace_all(szText, iLen, "'", "")
	replace_all(szText, iLen, "`", "")
	replace_all(szText, iLen, "\\", "")
	replace_all(szText, iLen, "^"", "")
}

stock PkzSqlClean(szText[], iLen)
{
	replace_all(szText, iLen, "'", "")
	replace_all(szText, iLen, "`", "")
	replace_all(szText, iLen, "\\", "")
	replace_all(szText, iLen, "^"", "")
}

stock PkzRecordFinish(id, iTimeMs, const szRunType[])
{
	if (g_hLocalTuple == Empty_Handle)
	{
		kz_chat(id, "%L", id, "KZ_STORAGE_UNAVAILABLE")
		if (g_iForwardRunFinished)
		{
			new iReturn
			ExecuteForward(g_iForwardRunFinished, iReturn, id, g_iCategory[id], iTimeMs, 0, szRunType)
		}
		return
	}

	new szKey[64], szAuthId[64], szCatSlug[32]
	PkzGetPlayerKey(id, szKey, charsmax(szKey), szAuthId, charsmax(szAuthId))
	PkzGetQueryCategorySlug(g_iCategory[id], szCatSlug, charsmax(szCatSlug))
	new szQuery[1024]
	formatex(szQuery, charsmax(szQuery),
		"SELECT COALESCE((SELECT time_ms FROM kz_records WHERE mapname='%s' AND category='%s' AND run_type='%s' AND player_key='%s'),0), COALESCE((SELECT MIN(time_ms) FROM kz_records WHERE mapname='%s' AND category='%s' AND run_type='%s'),0)",
		g_szMapName, szCatSlug, szRunType, szKey, g_szMapName, szCatSlug, szRunType)

	new iData[6]
	iData[0] = id
	iData[1] = get_user_userid(id)
	iData[2] = iTimeMs
	iData[3] = g_iCategory[id]
	iData[4] = get_user_weapon(id)
	copy(g_szPendingRunType[id], 7, szRunType)
	g_bRecordPending[id] = true
	SQL_ThreadQuery(g_hLocalTuple, "PkzRecordLookupHandler", szQuery, iData, sizeof iData)
}

public PkzRecordLookupHandler(iFailState, Handle:hQuery, szError[], iErrorCode, iData[], iDataSize, Float:flQueueTime)
{
	new id = iData[0]
	if (iFailState != TQUERY_SUCCESS)
	{
		if (is_user_connected(id) && get_user_userid(id) == iData[1])
			g_bRecordPending[id] = false
		log_amx("[ProKreedz] Record query error #%d: %s", iErrorCode, szError)
		if (is_user_connected(id) && g_iForwardRunFinished)
		{
			new iReturn
			new szErrRunType[8]
			copy(szErrRunType, 7, g_szPendingRunType[id])
			ExecuteForward(g_iForwardRunFinished, iReturn, id, iData[3], iData[2], 0, szErrRunType)
		}
		return
	}

	if (!is_user_connected(id) || get_user_userid(id) != iData[1])
		return
	g_bRecordPending[id] = false

	new iOldTime = SQL_ReadResult(hQuery, 0)
	new iOldWr = SQL_ReadResult(hQuery, 1)
	new bool:bPersonalBest = (iOldTime == 0 || iData[2] < iOldTime)
	new bool:bWorldRecord = (iOldWr == 0 || iData[2] < iOldWr)

	if (bPersonalBest)
	{
		new szKey[64], szAuthId[64], szName[64], szDate[32], szServer[64], szQuery[1024], szCatSlug[32]
		PkzGetPlayerKey(id, szKey, charsmax(szKey), szAuthId, charsmax(szAuthId))
		get_user_name(id, szName, charsmax(szName))
		PkzSqlClean(szName, charsmax(szName))
		get_time("%Y-%m-%d %H:%M:%S", szDate, charsmax(szDate))
		get_pcvar_string(pkz_mysql_server, szServer, charsmax(szServer))
		if (!szServer[0])
			get_cvar_string("hostname", szServer, charsmax(szServer))
		PkzSqlClean(szServer, charsmax(szServer))
		PkzGetQueryCategorySlug(iData[3], szCatSlug, charsmax(szCatSlug))
		formatex(szQuery, charsmax(szQuery),
			"REPLACE INTO kz_records (mapname,category,run_type,player_key,authid,country,name,time_ms,recorded_at,weapon,server) VALUES ('%s','%s','%s','%s','%s','--','%s',%d,'%s','%s','%s')",
			g_szMapName, szCatSlug, g_szPendingRunType[id], szKey, szAuthId, szName, iData[2], szDate, g_weaponsnames[iData[4]], szServer)
		SQL_ThreadQuery(g_hLocalTuple, "PkzGenericQueryHandler", szQuery)
		PkzMirrorRecord(iData[3], g_szPendingRunType[id], szKey, szAuthId, szName, iData[2], szDate, g_weaponsnames[iData[4]], szServer)

		new szCatName[48]
		PkzGetCategoryName(iData[3], szCatName, charsmax(szCatName))
		if (bWorldRecord)
			kz_chat(id, "%L", id, "KZ_NEW_CATEGORY_WR", szCatName)
		else
			kz_chat(id, "%L", id, "KZ_NEW_PERSONAL_RECORD", szCatName)
	}

	if (g_iForwardRunFinished)
	{
		new iReturn
		ExecuteForward(g_iForwardRunFinished, iReturn, id, iData[3], iData[2], bWorldRecord ? 1 : 0, g_szPendingRunType[id])
	}
}

stock PkzMirrorRecord(iCategory, const szRunType[], const szKey[], const szAuthId[], const szName[], iTimeMs, const szDate[], const szWeapon[], const szServer[])
{
	if (!g_bMysqlReady || g_hMysqlTuple == Empty_Handle)
		return

	new szCatSlug[32], szQuery[1400]
	PkzGetQueryCategorySlug(iCategory, szCatSlug, charsmax(szCatSlug))
	formatex(szQuery, charsmax(szQuery),
		"INSERT INTO kz_records (mapname,category,run_type,player_key,authid,country,name,time_ms,recorded_at,weapon,server) VALUES ('%s','%s','%s','%s','%s','--','%s',%d,'%s','%s','%s') ON DUPLICATE KEY UPDATE name=VALUES(name),authid=VALUES(authid),server=VALUES(server),recorded_at=IF(VALUES(time_ms)<time_ms,VALUES(recorded_at),recorded_at),weapon=IF(VALUES(time_ms)<time_ms,VALUES(weapon),weapon),time_ms=LEAST(time_ms,VALUES(time_ms))",
		g_szMapName, szCatSlug, szRunType, szKey, szAuthId, szName, iTimeMs, szDate, szWeapon, szServer)
	SQL_ThreadQuery(g_hMysqlTuple, "PkzGenericQueryHandler", szQuery)
}

public PkzGenericQueryHandler(iFailState, Handle:hQuery, szError[], iErrorCode, iData[], iDataSize, Float:flQueueTime)
{
	if (iFailState != TQUERY_SUCCESS)
		log_amx("[ProKreedz] SQL query error #%d: %s", iErrorCode, szError)
}

public ProTop15Show(id)
{
	copy(g_szTopRunType[id], 7, "pro")
	return Top15CategoryMenu(id)
}

public NoobTop15Show(id)
{
	copy(g_szTopRunType[id], 7, "noob")
	return Top15CategoryMenu(id)
}

public ProMotdShow(id)
{
	copy(g_szTopRunType[id], 7, "pro")
	return ShowCategoryTop(id, g_iCategory[id])
}

public NoobMotdShow(id)
{
	copy(g_szTopRunType[id], 7, "noob")
	return ShowCategoryTop(id, g_iCategory[id])
}

public CategoryTopShow(id)
{
	copy(g_szTopRunType[id], 7, "pro")
	return Top15CategoryMenu(id)
}
public CategoryTopHandler(iFailState, Handle:hQuery, szError[], iErrorCode, iData[], iDataSize, Float:flQueueTime)
{
	new id = iData[0]
	if (iFailState != TQUERY_SUCCESS)
	{
		log_amx("[ProKreedz] Top15 query error #%d: %s", iErrorCode, szError)
		if (iDataSize >= 4 && iData[3] == 0 && g_bMysqlReady && g_hMysqlTuple != Empty_Handle)
		{
			new iCat = iData[1], iData2[4], szCatSlug[32]
			iData2[0] = id; iData2[1] = iCat; iData2[2] = iData[2]; iData2[3] = 1
			new szQ[384]
			PkzGetQueryCategorySlug(iCat, szCatSlug, charsmax(szCatSlug))
			formatex(szQ, charsmax(szQ), "SELECT name,time_ms,recorded_at FROM kz_records WHERE mapname='%s' AND category='%s' AND run_type='%s' ORDER BY time_ms ASC LIMIT 15", g_szMapName, szCatSlug, iData[2] ? "noob" : "pro")
			SQL_ThreadQuery(g_hMysqlTuple, "CategoryTopHandler", szQ, iData2, sizeof iData2)
		}
		return
	}
	if (!is_user_connected(id))
		return

	static szHtml[4096]
	new iLen
	new szRunLabel[8] = "PRO"
	if (iDataSize >= 3 && iData[2] == 1)
		copy(szRunLabel, 7, "NOOB")
	new szCatName[48]
	if (get_pcvar_num(g_pPkzSimpleMode))
		copy(szCatName, charsmax(szCatName), "Simple")
	else
		PkzGetCategoryName(iData[1], szCatName, charsmax(szCatName))
	iLen = formatex(szHtml, charsmax(szHtml), "<html><head><meta charset=utf-8><style>body{background:#0a0a0a;color:#e0e0e0;font:13px Verdana;margin:12px}.title{color:#fff;font-size:15px;font-weight:bold;text-align:center;padding:8px 0;border-bottom:2px solid #333}.navbar{background:#111;padding:6px;margin-bottom:10px;text-align:center;border:1px solid #333}.navbar a{color:#aaa;text-decoration:none;margin:0 8px;font-weight:bold}.navbar a:hover{color:#fff}.navbar span{color:#fff;margin:0 8px;font-weight:bold;border-bottom:2px solid #555}table{width:100%%;border-collapse:collapse}th{background:#1a1a1a;color:#fff;padding:7px 8px;border:1px solid #333;font-size:12px}td{padding:5px 8px;border:1px solid #222;color:#ccc;font-size:12px}.alt td{background:#0f0f0f}.no-rec{text-align:center;color:#666;padding:30px;font-size:13px}</style></head><body><div class=title>ProKreedz - %s - %s [%s]</div>", g_szMapName, szCatName, szRunLabel)

	if (!SQL_NumResults(hQuery))
	{
		if (iDataSize >= 4 && iData[3] == 0 && g_bMysqlReady && g_hMysqlTuple != Empty_Handle)
		{
			new iCat = iData[1], iData2[4], szCatSlug2[32]
			iData2[0] = id; iData2[1] = iCat; iData2[2] = iData[2]; iData2[3] = 1
			new szQ[384]
			PkzGetQueryCategorySlug(iCat, szCatSlug2, charsmax(szCatSlug2))
			formatex(szQ, charsmax(szQ), "SELECT name,time_ms,recorded_at FROM kz_records WHERE mapname='%s' AND category='%s' AND run_type='%s' ORDER BY time_ms ASC LIMIT 15", g_szMapName, szCatSlug2, iData[2] ? "noob" : "pro")
			SQL_ThreadQuery(g_hMysqlTuple, "CategoryTopHandler", szQ, iData2, sizeof iData2)
			return
		}
		iLen += formatex(szHtml[iLen], charsmax(szHtml) - iLen, "<div class=no-rec>No records found in this category.<br><br>Be the first to set one!</div>")
		formatex(szHtml[iLen], charsmax(szHtml) - iLen, "</body></html>")
		show_motd(id, szHtml, "Category Top 15")
		return
	}

	iLen += formatex(szHtml[iLen], charsmax(szHtml) - iLen, "<table><tr><th>#</th><th>Player</th><th>Time</th><th>Date</th></tr>")
	new iRank = 1
	new bool:bAlt
	while (SQL_MoreResults(hQuery) && iLen < charsmax(szHtml) - 256)
	{
		new szName[64], szSafeName[96], szDate[32]
		SQL_ReadResult(hQuery, 0, szName, charsmax(szName))
		copy(szSafeName, charsmax(szSafeName), szName)
		PkzHtmlEscape(szSafeName, charsmax(szSafeName))
		new iTimeMs = SQL_ReadResult(hQuery, 1)
		SQL_ReadResult(hQuery, 2, szDate, charsmax(szDate))
		new iMinutes = iTimeMs / 60000
		new iSeconds = (iTimeMs / 1000) % 60
		new iMillis = iTimeMs % 1000
		iLen += formatex(szHtml[iLen], charsmax(szHtml) - iLen, "<tr%s><td>%d</td><td>%s</td><td>%02d:%02d.%03d</td><td>%s</td></tr>", bAlt ? " class=alt" : "", iRank++, szSafeName, iMinutes, iSeconds, iMillis, szDate)
		bAlt = !bAlt
		SQL_NextRow(hQuery)
	}
	formatex(szHtml[iLen], charsmax(szHtml) - iLen, "</table></body></html>")
	show_motd(id, szHtml, "Category Top 15")
}

stock PkzHtmlEscape(szText[], iLength)
{
	replace_all(szText, iLength, "&", "&amp;")
	replace_all(szText, iLength, "<", "&lt;")
	replace_all(szText, iLength, ">", "&gt;")
}

public CategoryRankShow(id)
{
	if (g_hLocalTuple == Empty_Handle)
		return PLUGIN_HANDLED

	new szKey[64], szAuthId[64], szQuery[640], iData[2], szCatSlug[32]
	PkzGetPlayerKey(id, szKey, charsmax(szKey), szAuthId, charsmax(szAuthId))
	PkzGetQueryCategorySlug(g_iCategory[id], szCatSlug, charsmax(szCatSlug))
	formatex(szQuery, charsmax(szQuery),
		"SELECT time_ms,(SELECT COUNT(*)+1 FROM kz_records r2 WHERE r2.mapname='%s' AND r2.category='%s' AND r2.time_ms<r1.time_ms) FROM kz_records r1 WHERE mapname='%s' AND category='%s' AND player_key='%s'",
		g_szMapName, szCatSlug, g_szMapName, szCatSlug, szKey)
	iData[0] = id
	iData[1] = g_iCategory[id]
	SQL_ThreadQuery(g_hLocalTuple, "CategoryRankHandler", szQuery, iData, sizeof iData)
	return PLUGIN_HANDLED
}

public CategoryRankHandler(iFailState, Handle:hQuery, szError[], iErrorCode, iData[], iDataSize, Float:flQueueTime)
{
	if (iFailState != TQUERY_SUCCESS || !is_user_connected(iData[0]))
		return
	new szCatName[48]
	PkzGetCategoryName(iData[1], szCatName, charsmax(szCatName))
	if (!SQL_NumResults(hQuery))
	{
		kz_chat(iData[0], "%L", iData[0], "KZ_NO_CATEGORY_RECORD", szCatName)
		return
	}
	kz_chat(iData[0], "%L", iData[0], "KZ_CATEGORY_RANK", szCatName, SQL_ReadResult(hQuery, 1))
}

public plugin_end()
{
	if (g_hLocalTuple != Empty_Handle)
		SQL_FreeHandle(g_hLocalTuple)
	if (g_hMysqlTuple != Empty_Handle)
		SQL_FreeHandle(g_hMysqlTuple)
	if (g_iForwardRunStarted)
		DestroyForward(g_iForwardRunStarted)
	if (g_iForwardRunReset)
		DestroyForward(g_iForwardRunReset)
	if (g_iForwardRunFinished)
		DestroyForward(g_iForwardRunFinished)
}

// You reached the end of file
// The original plugin was made by p4ddY 
// This plugin was edited by nucLeaR
// Version 2.31

public PkzCmdTop15Cat(id)
{
	new szArg[8]
	read_argv(1, szArg, charsmax(szArg))
	new iCategory = str_to_num(szArg)
	if (0 <= iCategory && iCategory < PKZ_CATEGORY_COUNT)
		ShowCategoryTop(id, iCategory)
	return PLUGIN_HANDLED
}

public Top15CategoryMenu(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (get_pcvar_num(g_pPkzSimpleMode))
		return ShowCategoryTop(id, 0)

	new szPrefix[32];
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))

	new title[64], szItem[64], szInfo[8];
	formatex(title, 63, "%L", id, "KZ_TOP15_MOD_TITLE", szPrefix)
	new iMenu = menu_create(title, "Top15ModMenuHandler")

	for (new iMod = 0; iMod < PKZ_MOD_COUNT; iMod++)
	{
		num_to_str(iMod, szInfo, charsmax(szInfo))
		formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, g_szModName[iMod])
		menu_additem(iMenu, szItem, szInfo)
	}

	PkzMenuSetNavigation(iMenu, PKZ_MENU_NAV_MAIN)
	PkzMenuDisplaySafe(id, iMenu)
	return PLUGIN_HANDLED
}

public Top15ModMenuHandler(id, iMenu, iItem)
{
	if (iItem < 0)
	{
		menu_destroy(iMenu)
		if (iItem == MENU_EXIT && is_user_connected(id))
			return kz_menu(id)
		return PLUGIN_HANDLED
	}

	new szInfo[8], szName[64], iAccess, iCallback
	menu_item_getinfo(iMenu, iItem, iAccess, szInfo, charsmax(szInfo), szName, charsmax(szName), iCallback)
	new iMod = str_to_num(szInfo)
	menu_destroy(iMenu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (0 <= iMod && iMod < PKZ_MOD_COUNT)
	{
		Top15FpsMenu(id, iMod)
	}

	return PLUGIN_HANDLED
}

stock Top15FpsMenu(id, iMod)
{
	if (!is_user_connected(id))
		return

	new szPrefix[32]
	get_pcvar_string(kz_prefix, szPrefix, charsmax(szPrefix))

	new title[64], szItem[64], szInfo[8]
	formatex(title, 63, "%L", id, "KZ_TOP15_FPS_TITLE", szPrefix, g_szModName[iMod])
	new iMenu = menu_create(title, "Top15FpsMenuHandler")

	for (new iFps = 0; iFps < PKZ_FPS_COUNT; iFps++)
	{
		new iCat = PkzCalcCategoryIndex(bool:(iMod & PKZ_MOD_BHOP), bool:(iMod & PKZ_MOD_DOUBLEJUMP), bool:(iMod & PKZ_MOD_LOWGRAV), iFps)
		num_to_str(iCat, szInfo, charsmax(szInfo))
		formatex(szItem, charsmax(szItem), "\y%s\w %s", szPrefix, g_szFpsName[iFps])
		menu_additem(iMenu, szItem, szInfo)
	}

	PkzMenuSetNavigation(iMenu, PKZ_MENU_NAV_BACK)
	PkzMenuDisplaySafe(id, iMenu)
}

public Top15FpsMenuHandler(id, iMenu, iItem)
{
	if (iItem < 0)
	{
		menu_destroy(iMenu)
		if (iItem == MENU_EXIT && is_user_connected(id))
			return Top15CategoryMenu(id)
		return PLUGIN_HANDLED
	}

	new szInfo[8], szName[64], iAccess, iCallback
	menu_item_getinfo(iMenu, iItem, iAccess, szInfo, charsmax(szInfo), szName, charsmax(szName), iCallback)
	new iCategory = str_to_num(szInfo)
	menu_destroy(iMenu)
	if (!is_user_connected(id))
		return PLUGIN_HANDLED

	if (0 <= iCategory && iCategory < PKZ_CATEGORY_COUNT)
		ShowCategoryTop(id, iCategory)

	return PLUGIN_HANDLED
}

stock ShowCategoryTop(id, iCategory)
{
	if (!g_szTopRunType[id][0])
		copy(g_szTopRunType[id], 7, "pro")

	if (PkzShowWebTop15(id, iCategory))
		return PLUGIN_HANDLED

	if (g_hLocalTuple == Empty_Handle && (!g_bMysqlReady || g_hMysqlTuple == Empty_Handle))
	{
		kz_chat(id, "%L", id, "KZ_STORAGE_UNAVAILABLE")
		return PLUGIN_HANDLED
	}

	new szCatSlug[32], szQuery[384], iData[4]
	PkzGetQueryCategorySlug(iCategory, szCatSlug, charsmax(szCatSlug))
	formatex(szQuery, charsmax(szQuery), "SELECT name,time_ms,recorded_at FROM kz_records WHERE mapname='%s' AND category='%s' AND run_type='%s' ORDER BY time_ms ASC LIMIT 15", g_szMapName, szCatSlug, g_szTopRunType[id])
	iData[0] = id
	iData[1] = iCategory
	iData[2] = equal(g_szTopRunType[id], "noob") ? 1 : 0
	iData[3] = g_hLocalTuple != Empty_Handle ? 0 : 1
	SQL_ThreadQuery(iData[3] == 0 ? g_hLocalTuple : g_hMysqlTuple, "CategoryTopHandler", szQuery, iData, sizeof iData)
	return PLUGIN_HANDLED
}

stock bool:PkzShowWebTop15(id, iCategory)
{
	if (!get_pcvar_num(kz_web_motd_enabled) || !is_user_connected(id))
		return false

	new szBaseUrl[192]
	get_pcvar_string(kz_web_motd_url, szBaseUrl, charsmax(szBaseUrl))
	trim(szBaseUrl)
	if (!szBaseUrl[0] || (containi(szBaseUrl, "http://") != 0 && containi(szBaseUrl, "https://") != 0))
		return false

	new szCategory[32], szSeparator[2], szTargetUrl[384], szHtml[512]
	PkzGetQueryCategorySlug(iCategory, szCategory, charsmax(szCategory))
	copy(szSeparator, charsmax(szSeparator), contain(szBaseUrl, "?") == -1 ? "?" : "&")
	formatex(szTargetUrl, charsmax(szTargetUrl), "%s%smap=%s&category=%s&run_type=%s",
		szBaseUrl, szSeparator, g_szMapName, szCategory, g_szTopRunType[id])
	formatex(szHtml, charsmax(szHtml),
		"<html><head><meta http-equiv=^"Refresh^" content=^"0;url=%s^"></head><body>Loading Top 15...</body></html>",
		szTargetUrl)
	show_motd(id, szHtml, "Web Top 15")
	return true
}

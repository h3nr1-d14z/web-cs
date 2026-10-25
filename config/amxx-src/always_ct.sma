#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <hamsandwich>
#include <fakemeta>

#define PLUGIN "Always CT"
#define VERSION "1.0"
#define AUTHOR "OpenAI"

new g_pEnabled
new g_msgVGUIMenu
new g_msgShowMenu

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)
	g_pEnabled = register_cvar("always_ct_enabled", "1")

	g_msgVGUIMenu = get_user_msgid("VGUIMenu")
	g_msgShowMenu = get_user_msgid("ShowMenu")

	if (g_msgVGUIMenu)
		register_message(g_msgVGUIMenu, "Message_VGUIMenu")
	if (g_msgShowMenu)
		register_message(g_msgShowMenu, "Message_ShowMenu")

	register_clcmd("jointeam", "CmdJoinTeam")
	register_clcmd("joinclass", "CmdJoinClass")

	RegisterHam(Ham_Spawn, "player", "FwdSpawn", 1)
}

public client_putinserver(id)
{
	if (!get_pcvar_num(g_pEnabled) || is_user_bot(id))
		return

	set_task(0.2, "ForceCt", id)
}

public CmdJoinTeam(id)
{
	if (!get_pcvar_num(g_pEnabled))
		return PLUGIN_CONTINUE

	new szArg[4]
	read_argv(1, szArg, charsmax(szArg))
	new iTeam = str_to_num(szArg)

	// 2 = CT, anything else -> CT
	if (iTeam != 2)
	{
		engclient_cmd(id, "jointeam", "2")
		return PLUGIN_HANDLED
	}

	return PLUGIN_CONTINUE
}

public CmdJoinClass(id)
{
	if (!get_pcvar_num(g_pEnabled))
		return PLUGIN_CONTINUE

	engclient_cmd(id, "joinclass", "5")
	return PLUGIN_HANDLED
}

public Message_VGUIMenu(msg_id, msg_dest, msg_entity)
{
	if (!get_pcvar_num(g_pEnabled))
		return PLUGIN_CONTINUE

	new szName[64]
	get_msg_arg_string(2, szName, charsmax(szName))

	if (equal(szName, "team") || equal(szName, "class_T") || equal(szName, "class_CT"))
		return PLUGIN_HANDLED

	return PLUGIN_CONTINUE
}

public Message_ShowMenu(msg_id, msg_dest, msg_entity)
{
	if (!get_pcvar_num(g_pEnabled))
		return PLUGIN_CONTINUE

	new szBuffer[128]
	get_msg_arg_string(4, szBuffer, charsmax(szBuffer))

	if (containi(szBuffer, "Team_Select") != -1 || containi(szBuffer, "team_select") != -1)
		return PLUGIN_HANDLED

	return PLUGIN_CONTINUE
}

public ForceCt(id)
{
	if (!is_user_connected(id))
		return

	cs_set_user_team(id, CS_TEAM_CT)

	if (!is_user_alive(id))
		cs_user_spawn(id)
}

public FwdSpawn(id)
{
	if (!get_pcvar_num(g_pEnabled) || !is_user_alive(id))
		return

	if (cs_get_user_team(id) != CS_TEAM_CT)
		cs_set_user_team(id, CS_TEAM_CT)
}

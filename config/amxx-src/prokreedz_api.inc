#if defined _prokreedz_api_included
	#endinput
#endif
#define _prokreedz_api_included

#pragma library prokreedz

#define PKZ_FPS_COUNT 7
#define PKZ_MOD_COUNT 8
#define PKZ_CATEGORY_COUNT 56

enum _:PkzModType
{
	PKZ_MOD_BHOP = 4,
	PKZ_MOD_DOUBLEJUMP = 2,
	PKZ_MOD_LOWGRAV = 1
}

enum _:PkzZoneType
{
	PKZ_ZONE_START = 0,
	PKZ_ZONE_FINISH
}

native pkz_get_user_category(id)
native pkz_is_user_running(id)
native pkz_is_user_paused(id)
native pkz_get_category_slug(iCategory, szBuffer[], iLength)
native pkz_get_category_name(iCategory, szBuffer[], iLength)
native pkz_get_user_mod(id, iModType)
native pkz_set_user_mod(id, iModType, iEnabled)
native pkz_get_simple_mode()
native pkz_get_player_key(id, szBuffer[], iLength)
native pkz_open_main_menu(id)
native pkz_enter_spectator(id)

forward pkz_run_started(id, iCategory, run_type[])
forward pkz_run_reset(id)
forward pkz_run_finished(id, iCategory, iTimeMs, iNewWorldRecord, run_type[])

stock PkzCalcCategoryIndex(iBhop, iDJ, iLG, iFpsIdx)
{
	return ((iBhop ? PKZ_MOD_BHOP : 0) | (iDJ ? PKZ_MOD_DOUBLEJUMP : 0) | (iLG ? PKZ_MOD_LOWGRAV : 0)) * PKZ_FPS_COUNT + iFpsIdx
}

stock PkzGetFpsFromCategory(iCategory)
{
	return iCategory % PKZ_FPS_COUNT
}

stock PkzGetModFromCategory(iCategory)
{
	return iCategory / PKZ_FPS_COUNT
}

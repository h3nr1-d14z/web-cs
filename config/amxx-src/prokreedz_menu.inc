#if defined _prokreedz_menu_included
	#endinput
#endif
#define _prokreedz_menu_included

enum _:PkzMenuNavigation
{
	PKZ_MENU_NAV_EXIT = 0,
	PKZ_MENU_NAV_BACK,
	PKZ_MENU_NAV_MAIN
}

stock PkzMenuSetNavigation(iMenu, iNavigation)
{
	menu_setprop(iMenu, MPROP_BACKNAME, "Previous Page")
	menu_setprop(iMenu, MPROP_NEXTNAME, "Next Page")

	switch (iNavigation)
	{
		case PKZ_MENU_NAV_BACK: menu_setprop(iMenu, MPROP_EXITNAME, "Back")
		case PKZ_MENU_NAV_MAIN: menu_setprop(iMenu, MPROP_EXITNAME, "Back to Main Menu")
		default: menu_setprop(iMenu, MPROP_EXITNAME, "Exit")
	}
}

stock bool:PkzMenuDisplaySafe(id, iMenu, iPage = 0)
{
	if (!is_user_connected(id))
	{
		menu_destroy(iMenu)
		return false
	}

	menu_display(id, iMenu, iPage)
	return true
}

-- LuCI Lua-controller compatibility for luci-app-campus-auth.
--
-- Two LuCI generations exist in the wild:
--   * modern (client-rendered): reads /usr/share/luci/menu.d, serves
--     client-side JS views. Our menu.d + *.js files handle it.
--   * legacy (server-rendered Lua dispatcher, e.g. ImmortalWrt builds):
--     ignores menu.d entirely and has no JS view runtime.
-- This controller registers the menu ONLY on legacy builds, detected by
-- the dispatcher NOT referencing menu.d. The dispatcher bytecode-caches
-- index functions, so no helper functions or upvalues are used here -
-- everything lives inside index() and runs again on each cache build.
--
-- The legacy pages are server-rendered: a CBI settings form and a
-- hand-rolled status page (see view/campus-auth/*.htm and
-- model/cbi/campus-auth/settings.lua).

module("luci.controller.campus-auth", package.seeall)

function index()
	-- Legacy-dispatcher detection: if the interpreter's dispatcher reads
	-- /usr/share/luci/menu.d, the modern UI handles rendering; bail out
	-- so the menu is not registered twice.
	local src = ""
	local f = io.open("/usr/lib/lua/luci/dispatcher.lua", "r")
	if f then
		src = f:read("*a") or ""
		f:close()
	end
	if src:find("/usr/share/luci/menu.d", 1, true) then
		return
	end

	if not nixio.fs.access("/etc/config/campus-auth") then
		return
	end

	local page = entry({"admin", "services", "campus-auth"},
		firstchild(), "校园网认证", 65)
	page.dependent = false

	entry({"admin", "services", "campus-auth", "status"},
		template("campus-auth/status"), "运行状态", 10).dependent = false

	entry({"admin", "services", "campus-auth", "settings"},
		cbi("campus-auth/settings"), "参数设置", 20).dependent = false

	entry({"admin", "services", "campus-auth", "auth"},
		call("action_auth")).leaf = true
	entry({"admin", "services", "campus-auth", "pause"},
		call("action_pause")).leaf = true
	entry({"admin", "services", "campus-auth", "resume"},
		call("action_resume")).leaf = true

	function action_auth()
		local pf = io.open("/etc/campus-auth.pause", "r")
		local paused = false
		if pf then
			paused = (pf:read("*l") or "") == os.date("%Y-%m-%d")
			pf:close()
		end
		if paused then
			os.execute("(sleep 1; /etc/init.d/campus-auth restart) >/dev/null 2>&1 &")
		else
			os.execute("(nohup /usr/bin/campus-auth >/dev/null 2>&1 &) >/dev/null 2>&1")
		end
		luci.http.redirect(luci.dispatcher.build_url("admin/services/campus-auth/status"))
	end

	function action_pause()
		os.execute("/usr/bin/campus-auth --pause-today >/dev/null 2>&1")
		luci.http.redirect(luci.dispatcher.build_url("admin/services/campus-auth/status"))
	end

	function action_resume()
		os.execute("/usr/bin/campus-auth --resume >/dev/null 2>&1")
		os.execute("(nohup /usr/bin/campus-auth >/dev/null 2>&1 &) >/dev/null 2>&1")
		luci.http.redirect(luci.dispatcher.build_url("admin/services/campus-auth/status"))
	end
end

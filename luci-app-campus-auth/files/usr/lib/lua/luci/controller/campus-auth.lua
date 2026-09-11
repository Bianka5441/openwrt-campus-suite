-- LuCI Lua-controller compatibility for luci-app-campus-auth.
--
-- Two LuCI generations exist in the wild:
--   * modern (client-rendered): reads /usr/share/luci/menu.d, serves
--     client-side JS views. Our menu.d + *.js files handle it.
--   * legacy (server-rendered Lua dispatcher, e.g. ImmortalWrt builds):
--     ignores menu.d, has no JS view runtime, and template() targets
--     are NOT wrapped by the theme - only CBI gets header/footer.
-- This controller registers the menu ONLY on legacy builds, detected by
-- the dispatcher NOT referencing menu.d; the status page is served
-- through a call() handler that renders header + view + footer by hand.
--
-- CAVEAT: the legacy dispatcher bytecode-caches the index tree, so all
-- helpers/action handlers must live at MODULE level (defined when the
-- file is require()d on demand), never as closures inside index().

module("luci.controller.campus-auth", package.seeall)

local function paused_today()
	local f = io.open("/etc/campus-auth.pause", "r")
	if not f then
		return false
	end
	local v = f:read("*l") or ""
	f:close()
	return v == os.date("%Y-%m-%d")
end

local function redirect_status()
	luci.http.redirect(luci.dispatcher.build_url("admin/services/campus-auth/status"))
end

function render_status()
	require("luci.template").render("header")
	require("luci.template").render("campus-auth/status")
	require("luci.template").render("footer")
end

-- Bare status fragment (no theme wrap); the status page polls this via XHR
-- and swaps only its content area, so the page never blanks on reload.
function render_fragment()
	luci.http.prepare_content("text/html; charset=utf-8")
	require("luci.template").render("campus-auth/status_content")
end

function action_auth()
	if paused_today() then
		-- respect the quota-pause; make no portal requests
		os.execute("(sleep 1; /etc/init.d/campus-auth restart) >/dev/null 2>&1 &")
	else
		os.execute("(nohup /usr/bin/campus-auth >/dev/null 2>&1 &) >/dev/null 2>&1")
	end
	redirect_status()
end

function action_pause()
	os.execute("/usr/bin/campus-auth --pause-today >/dev/null 2>&1")
	redirect_status()
end

function action_resume()
	os.execute("/usr/bin/campus-auth --resume >/dev/null 2>&1")
	os.execute("(nohup /usr/bin/campus-auth >/dev/null 2>&1 &) >/dev/null 2>&1")
	redirect_status()
end

function index()
	-- Legacy-dispatcher detection: if the installed dispatcher reads
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
		call("render_status"), "运行状态", 10).dependent = false

	entry({"admin", "services", "campus-auth", "fragment"},
		call("render_fragment")).leaf = true

	entry({"admin", "services", "campus-auth", "settings"},
		cbi("campus-auth/settings"), "参数设置", 20).dependent = false

	entry({"admin", "services", "campus-auth", "auth"},
		call("action_auth")).leaf = true
	entry({"admin", "services", "campus-auth", "pause"},
		call("action_pause")).leaf = true
	entry({"admin", "services", "campus-auth", "resume"},
		call("action_resume")).leaf = true
end

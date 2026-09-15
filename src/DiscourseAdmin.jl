"""
    DiscourseAdmin

A simple package to manage Discourse `admin` configuration.

This treats the admin settings as a simple key/value store.
The values are contents of files, and the `admin/**` path is the API
route. An entry on a localized route is `route/key/locale.ext` (e.g.
`admin/customize/site_texts/guidelines_topic.body/en.md`); an entry on
a locale-less route is simply `route/key.ext`. The extension is only
for display on GitHub. Pulling mirrors every locale the site has
entries in, so a new key/value route needs nothing but its
(`.gitkeep`-held) directory. The one route that isn't a key/value store
is [`FLAGS`](@ref), whose entries are JSON records keyed by id.

The two CLI entry points used by the GitHub workflows are
[`main_pull`](@ref) (mirror the live state into the repository) and
[`main_push`](@ref) (apply committed changes to the live site).
"""
module DiscourseAdmin

using HTTP
using JSON

export Client

const DEFAULT_BASE_URL = "https://discourse.julialang.org"

# ---------------------------------------------------------------------------
# The Discourse admin API

"""
    Client(; base_url=DEFAULT_BASE_URL, api_key, api_user)

A connection to the admin API of a Discourse instance.
"""
Base.@kwdef struct Client
    base_url::String = DEFAULT_BASE_URL
    api_key::String
    api_user::String
end

"""
    client_from_env() -> Client

Construct a [`Client`](@ref) from the `API_KEY` and `API_USER` environment
variables, with `DISCOURSE_URL` optionally overriding the instance URL.
"""
function client_from_env()
    (isempty(get(ENV, "API_KEY", "")) || isempty(get(ENV, "API_USER", ""))) &&
        error("API_KEY and API_USER must be set")
    return Client(base_url = get(ENV, "DISCOURSE_URL", DEFAULT_BASE_URL),
                  api_key = ENV["API_KEY"], api_user = ENV["API_USER"])
end

auth_headers(c::Client) = ["Api-Key" => c.api_key, "Api-Username" => c.api_user]

get_json(c::Client, url; query = Pair{String,String}[]) =
    JSON.parse(HTTP.get(url; query, headers = auth_headers(c)).body)

# Discourse is Rails: a route's JSON objects and form fields use the
# singular of its last segment (admin/customize/site_texts → site_text)
singular(route) = chopsuffix(basename(route), "s")

endpoint(c::Client, route, key = nothing) =
    "$(c.base_url)/$route$(isnothing(key) ? "" : "/$(HTTP.escapeuri(key))")"

# The site texts API requires an explicit locale on every request; routes
# without locale support simply have none to send.
locale_query(locale) = isnothing(locale) ? Pair{String,String}[] : ["locale" => locale]

"""
    configured_keys(c::Client, route; locale=nothing) -> Vector{String}

The keys of every entry currently configured on the `route` endpoint,
following `extras.has_more` pagination through the `page` parameter.
"""
function configured_keys(c::Client, route; locale = nothing)
    keys = String[]
    page = 0
    while true
        data = get_json(c, "$(endpoint(c, route)).json";
                        query = [["overridden" => "true", "page" => string(page)];
                                 locale_query(locale)])
        append!(keys, String[t["id"] for t in data[basename(route)]])
        get(get(data, "extras", Dict()), "has_more", false) || return keys
        page += 1
    end
end

"""
    get_value(c::Client, route, key; locale=nothing) -> String

The currently-configured value of `key` on the `route` endpoint.
"""
get_value(c::Client, route, key; locale = nothing) =
    get_json(c, "$(endpoint(c, route, key)).json";
             query = locale_query(locale))[singular(route)]["value"]::String

"""
    set_value!(c::Client, route, key, value; locale=nothing)

Create or update the configuration of `key` on the `route` endpoint.
"""
function set_value!(c::Client, route, key, value; locale = nothing)
    if route == FLAGS
        # A file named by an id updates that flag; any other name creates a new
        # one, which the following pull re-files under the id Discourse assigns
        headers = [auth_headers(c); "Content-Type" => "application/json"]
        all(isdigit, key) ? HTTP.put(endpoint(c, route, key); headers, body = value) :
                            HTTP.post(endpoint(c, route); headers, body = value)
    else
        form = Dict("$(singular(route))[value]" => value)
        isnothing(locale) || (form["$(singular(route))[locale]"] = locale)
        # HTTP form-encodes a Dict body and sets the Content-Type itself
        HTTP.put(endpoint(c, route, key); headers = auth_headers(c), body = form)
    end
    return nothing
end

"""
    reset_value!(c::Client, route, key; locale=nothing)

Remove the configuration of `key`, reverting it to the Discourse default.
"""
function reset_value!(c::Client, route, key; locale = nothing)
    HTTP.delete(endpoint(c, route, key);
                query = locale_query(locale), headers = auth_headers(c))
    return nothing
end

"""
    available_locales(c::Client) -> Vector{String}

Every locale the instance supports, read from the `default_locale` site
setting's valid values.
"""
function available_locales(c::Client)
    settings = get_json(c, "$(c.base_url)/admin/site_settings.json")["site_settings"]
    i = findfirst(s -> s["setting"] == "default_locale", settings)
    isnothing(i) && error("could not determine the available locales from the site settings")
    return String[v["value"] for v in settings[i]["valid_values"]]
end

# Custom flags are records rather than strings, addressed by the integer id
# Discourse assigns at creation. They aren't listed at their own route:
# /site.json carries every flag, built-in and custom alike, with its full
# record. An entry's value is the JSON object the admin UI sends to create or
# update a flag, i.e. exactly its settable fields.
const FLAGS = "admin/config/flags"
const FLAG_FIELDS = (:name, :description, :applies_to, :require_message, :enabled, :auto_action_type)

flag_entries(c::Client) =
    [string(f["id"]) => flag_value(f)
     for f in get_json(c, "$(c.base_url)/site.json")["post_action_types"]
     if f["is_flag"] && !f["system"]]

# The canonical file form of a flag: its settable fields, in a fixed order
flag_value(f) = JSON.json(NamedTuple{FLAG_FIELDS}(Tuple(f[String(k)] for k in FLAG_FIELDS)), 2) * "\n"

"""
    entries(c::Client, route; locale=nothing) -> Vector{Pair{String,String}}

The key and current value of every entry configured on the `route` endpoint.
"""
entries(c::Client, route; locale = nothing) = route == FLAGS ? flag_entries(c) :
    [key => get_value(c, route, key; locale) for key in configured_keys(c, route; locale)]

# ---------------------------------------------------------------------------
# Repository conventions

"The repository directory mirroring the admin API."
const ROOT = "admin"

# Extensions are only for display on GitHub; strip them to find the name
const DISPLAY_EXTENSION = r"\.(txt|md|json)$"
const LOCALE_SHAPE = r"^[a-z]{2}([_-][A-Za-z]{2})?$"

# Dotfiles (like a .gitkeep) are never entries
hidden(name) = startswith(name, ".")

# Of all the admin routes, only site_texts requires (and localizes by) a
# locale parameter; every other route ignores it.
localized(route) = basename(route) == "site_texts"

"""
    entry_for(file) -> (route, key, locale)

The API entry a repository file manages. A filename shaped like a locale
(`en`, `pt_BR`, `en-GB`) holds one translation of the key named by its
parent directory (`route/key/locale.ext`); any other filename is itself the
key of a locale-less entry (`route/key.ext`), with `locale === nothing`.
"""
function entry_for(file)
    name = replace(basename(file), DISPLAY_EXTENSION => "")
    occursin(LOCALE_SHAPE, name) && return (dirname(dirname(file)), basename(dirname(file)), name)
    return (dirname(file), name, nothing)
end

# The inverse of entry_for, used for keys that don't have a file yet
file_for(route, key, locale) =
    isnothing(locale) ? joinpath(route, "$key.$(route == FLAGS ? "json" : "txt")") :
                        joinpath(route, key, "$locale.txt")

"""
    config_routes() -> Vector{String}

The API routes the repository mirrors, declared by the files present: an
entry file declares its own route, and a dotfile (like a `.gitkeep`
holding an otherwise-empty route directory) declares its containing
directory.
"""
function config_routes()
    routes = Set{String}()
    isdir(ROOT) || return String[]
    for (path, _, files) in walkdir(ROOT), f in files
        push!(routes, hidden(f) ? path : entry_for(joinpath(path, f))[1])
    end
    return sort!(collect(routes))
end

"""
    existing_files(route) -> Dict{locale, Dict{key, file}}
    existing_files(route, locale) -> Dict{key, file}

The entry files a route currently has, grouped by locale (with
`locale === nothing` for locale-less entries), so an existing file's
display extension is preserved when its value is updated.
"""
function existing_files(route)
    bylocale = Dict{Union{String,Nothing},Dict{String,String}}()
    isdir(route) || return bylocale
    for (path, _, files) in walkdir(route), f in files
        hidden(f) && continue
        file = joinpath(path, f)
        r, key, locale = entry_for(file)
        r == route && (get!(bylocale, locale, Dict{String,String}())[key] = file)
    end
    return bylocale
end

existing_files(route, locale) = get(existing_files(route), locale, Dict{String,String}())

# ---------------------------------------------------------------------------
# Pull: mirror the live state into the repository

"""
    pull!(c::Client)

Mirror the live configuration of each route into its files, adding,
updating, and removing them so the repository exactly reflects the live
state. A [`localized`](@ref) route is mirrored for every locale the site
has entries in.
"""
function pull!(c::Client)
    routes = config_routes()
    locales = any(localized, routes) ? available_locales(c) : String[]
    for route in routes
        bylocale = existing_files(route)
        for locale in (localized(route) ? locales : [nothing])
            live = entries(c, route; locale)
            existing = get(bylocale, locale, Dict{String,String}())
            # nothing configured and nothing lingering to clean up
            isempty(live) && isempty(existing) && continue
            mirror!(route, locale, live, existing)
        end
    end
    return nothing
end

function mirror!(route, locale, live, existing)
    println("🔍 Found $(length(live)) configured entries in $route$(isnothing(locale) ? "" : " ($locale)")")

    for (key, value) in live
        file = get(() -> file_for(route, key, locale), existing, key)
        current = isfile(file) ? read(file, String) : nothing
        if current != value
            mkpath(dirname(file))
            write(file, value)
            println("📝 $(isnothing(current) ? "Added" : "Updated") $file")
        else
            println("✅ Unchanged $file")
        end
    end

    # Remove files whose entries are no longer configured on Discourse
    for (key, file) in existing
        if key ∉ first.(live)
            rm(file)
            println("🗑️  Removed $file (no longer configured)")
            # and the key directory, once its last translation is gone
            dir = dirname(file)
            dir != route && isempty(readdir(dir)) && rm(dir)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Push: apply committed changes to the live site

git(args...) = readchomp(Cmd(["git", args...]))

"""
    file_changes(range) -> Vector{Pair{String,Union{String,Nothing}}}

The changed files in the git commit `range` paired with their new contents
(read from the working tree, i.e. the range tip), where `nothing` indicates
a deletion. Only files on routes under `admin/` are considered; dotfiles
are ignored.
"""
function file_changes(range)
    changes = Pair{String,Union{String,Nothing}}[]
    for line in eachsplit(git("diff", "--name-status", "--no-renames", range), '\n'; keepempty = false)
        status, file = split(line, '\t')
        parts = splitpath(file)
        (length(parts) < 2 || first(parts) != ROOT || any(hidden, parts)) && continue
        push!(changes, String(file) => status == "D" ? nothing : read(String(file), String))
    end
    return changes
end

"""
    apply!(c::Client, changes)

Apply `changes` (as returned by [`file_changes`](@ref)) to each file's
namesake entry.
"""
function apply!(c::Client, changes)
    println("🔍 Sending $(length(changes)) updates:")
    for (file, content) in changes
        route, key, locale = entry_for(file)
        if isnothing(content)
            # Deleting the file reverts the entry to the Discourse default
            reset_value!(c, route, key; locale)
            println("🗑️  Reverted $file")
        else
            set_value!(c, route, key, content; locale)
            println("✅ Updated $file")
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Workflow entry points

# An ErrorException is a clean user-facing failure; anything else is a crash
main(f) = try
    f()
catch e
    e isa ErrorException || rethrow()
    println(stderr, "❌ $(e.msg)")
    exit(1)
end

"""
    main_pull()

Workflow entry point: mirror the live Discourse state into the repository.
"""
main_pull() = main(() -> pull!(client_from_env()))

"""
    main_push()

Workflow entry point: apply the changes the `BEFORE_SHA..HEAD` push added
to the live Discourse site. The workflow resolves `BEFORE_SHA` and
separately verifies that it still matches the live state before running
this.
"""
main_push() = main() do
    range = "$(ENV["BEFORE_SHA"])..HEAD"
    println("Diffing $range")
    changes = file_changes(range)
    if isempty(changes)
        println("No file changes detected")
        return
    end
    apply!(client_from_env(), changes)
end

end # module

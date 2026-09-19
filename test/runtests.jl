using DiscourseAdmin
using DiscourseAdmin: singular, entry_for, config_routes, existing_files, available_locales,
                      configured_keys, get_value, set_value!, reset_value!, entries, FLAGS,
                      pull!, file_changes, apply!, git, post_for, topic_for, get_post, set_post!
using HTTP
using JSON
using Test

# ---------------------------------------------------------------------------
# A mock Discourse instance: per-locale site text overrides (rejecting
# locale-less requests, like the real one), a locale-less "mock_things"
# route, the site settings listing the available locales, and custom
# flags (JSON records addressed by id, listed alongside the built-in
# flags in site.json). The site texts listing paginates like the real one
# (but with a tiny page size so the tests routinely cross page boundaries).
# Posts are found by topic id and post number but edited by their own id,
# and have the whitespace around their bodies stripped.

const POSTS_BY_ID = Dict{Int,Dict{String,Any}}()
const LAST_EDIT_REASON = Ref("")

const PAGE_SIZE = 2
const LAST_PUT_LOCALE = Ref("")

# The key addressed by a request path like "$route/some.key.json"
key_of(path, route) = HTTP.unescapeuri(chopsuffix(chopprefix(path, "$route/"), ".json"))

# The built-in flags every site lists, none of which is a mirrored entry
const BUILTIN_FLAGS = [
    Dict("id" => 2, "name" => "like", "is_flag" => false, "system" => true),
    Dict("id" => 4, "name" => "Inappropriate", "description" => "This post contains content that ...",
         "applies_to" => ["Post", "Topic"], "require_message" => false, "enabled" => true,
         "auto_action_type" => true, "is_flag" => true, "system" => true, "is_used" => true)]

function mock_discourse(state::Dict{String,Dict{String,String}}, things::Dict{String,String},
                        flags::Dict{Int,Dict{String,Any}}, port)
    st = "/admin/customize/site_texts"
    mt = "/admin/mock_things"
    ft = "/admin/config/flags"
    return HTTP.serve!("127.0.0.1", port) do req
        uri = HTTP.URI(req.target)
        path = uri.path
        qp = HTTP.queryparams(uri)

        if path == "/site.json"
            custom = [merge(f, Dict("id" => id, "is_flag" => true, "system" => false, "is_used" => false))
                      for (id, f) in sort!(collect(flags); by = first)]
            return HTTP.Response(200, JSON.json(Dict("default_locale" => "en",
                "post_action_types" => [BUILTIN_FLAGS; custom])))
        end

        if startswith(path, ft)
            # the flags API takes and returns JSON records, addressed by id
            HTTP.header(req, "Content-Type") == "application/json" || req.method == "DELETE" ||
                return HTTP.Response(400, "expected a JSON body")
            if req.method == "POST" && path == ft
                id = maximum(keys(flags); init = 1000) + 1
                flags[id] = JSON.parse(String(req.body))
                return HTTP.Response(200, JSON.json(Dict("flag" => merge(flags[id], Dict("id" => id)))))
            end
            id = tryparse(Int, chopprefix(path, "$ft/"))
            (isnothing(id) || !haskey(flags, id)) && return HTTP.Response(404, "no such flag")
            if req.method == "PUT"
                flags[id] = JSON.parse(String(req.body))
                return HTTP.Response(200, JSON.json(Dict("flag" => merge(flags[id], Dict("id" => id)))))
            elseif req.method == "DELETE"
                delete!(flags, id)
                return HTTP.Response(200, JSON.json(Dict("success" => "OK")))
            end
        end

        if startswith(path, "/posts/")
            if req.method == "GET"
                m = match(r"^/posts/by_number/(\d+)/(\d+)\.json$", path)
                found = isnothing(m) ? [] : [p for p in values(POSTS_BY_ID)
                    if (p["topic_id"], p["post_number"]) == Tuple(parse.(Int, m.captures))]
                return isempty(found) ? HTTP.Response(404, "no such post") :
                                        HTTP.Response(200, JSON.json(only(found)))
            elseif req.method == "PUT"
                id = tryparse(Int, key_of(path, "/posts"))
                haskey(POSTS_BY_ID, id) || return HTTP.Response(404, "no such post")
                form = HTTP.queryparams(String(req.body))
                POSTS_BY_ID[id]["raw"] = strip(form["post[raw]"])
                LAST_EDIT_REASON[] = form["post[edit_reason]"]
                return HTTP.Response(200, JSON.json(Dict("post" => POSTS_BY_ID[id])))
            end
        end

        if path == "/admin/site_settings.json"
            return HTTP.Response(200, JSON.json(Dict("site_settings" => [
                Dict("setting" => "title", "value" => "x"),
                Dict("setting" => "default_locale", "value" => "en",
                     "valid_values" => [Dict("value" => l) for l in ("en", "fr", "pt_BR")])])))
        end

        if startswith(path, st)
            # like the real site texts API, every action requires a locale
            locale = req.method == "PUT" ? get(HTTP.queryparams(String(req.body)), "site_text[locale]", "") :
                                           get(qp, "locale", "")
            isempty(locale) && return HTTP.Response(400, "invalid locale")
            texts = get!(state, locale, Dict{String,String}())
            if req.method == "GET" && path == "$st.json"
                ks = sort!(collect(keys(texts)))
                page = parse(Int, get(qp, "page", "0"))
                pageks = ks[min(page * PAGE_SIZE + 1, end + 1):min((page + 1) * PAGE_SIZE, end)]
                return HTTP.Response(200, JSON.json(Dict(
                    "site_texts" => [Dict("id" => k, "overridden" => true) for k in pageks],
                    "extras" => Dict("has_more" => length(ks) > (page + 1) * PAGE_SIZE))))
            end
            key = key_of(path, st)
            if req.method == "GET"
                haskey(texts, key) || return HTTP.Response(404, "no such site text")
                return HTTP.Response(200, JSON.json(Dict("site_text" => Dict("id" => key, "value" => texts[key]))))
            elseif req.method == "PUT"
                LAST_PUT_LOCALE[] = locale
                texts[key] = HTTP.queryparams(String(req.body))["site_text[value]"]
                return HTTP.Response(200, JSON.json(Dict("site_text" => Dict("id" => key, "value" => texts[key]))))
            elseif req.method == "DELETE"
                haskey(texts, key) || return HTTP.Response(404, "no such site text")
                delete!(texts, key)
                return HTTP.Response(200, "reverted")
            end
        end

        if startswith(path, mt)
            # a locale-less route: the locale parameter is simply ignored
            if req.method == "GET" && path == "$mt.json"
                return HTTP.Response(200, JSON.json(Dict(
                    "mock_things" => [Dict("id" => k) for k in sort!(collect(keys(things)))],
                    "extras" => Dict("has_more" => false))))
            end
            key = key_of(path, mt)
            req.method == "GET" && return haskey(things, key) ?
                HTTP.Response(200, JSON.json(Dict("mock_thing" => Dict("value" => things[key])))) :
                HTTP.Response(404, "no such thing")
            if req.method == "PUT"
                things[key] = HTTP.queryparams(String(req.body))["mock_thing[value]"]
                return HTTP.Response(200, "ok")
            end
        end

        return HTTP.Response(405, "unsupported")
    end
end

const PORT = 8397
const ROUTE = "admin/customize/site_texts"
state = Dict{String,Dict{String,String}}()
things = Dict{String,String}()
flags = Dict{Int,Dict{String,Any}}()
server = mock_discourse(state, things, flags, PORT)

const SPAM_LINK = Dict{String,Any}("name" => "Spam link", "description" => "Links to a spam site",
    "applies_to" => ["Post", "Topic"], "require_message" => false, "enabled" => true,
    "auto_action_type" => false)
const SPAM_LINK_FILE = """
{
  "name": "Spam link",
  "description": "Links to a spam site",
  "applies_to": [
    "Post",
    "Topic"
  ],
  "require_message": false,
  "enabled": true,
  "auto_action_type": false
}
"""
client = Client(base_url = "http://127.0.0.1:$PORT", api_key = "test-key", api_user = "test-user")

en() = get!(state, "en", Dict{String,String}())
fr() = get!(state, "fr", Dict{String,String}())

@testset "DiscourseAdmin" begin
    @testset "conventions" begin
        # a locale-shaped filename is one translation of its parent-directory key
        @test entry_for("$ROUTE/guidelines_topic.body/en.md") == (ROUTE, "guidelines_topic.body", "en")
        @test entry_for("$ROUTE/some.dotted.key/pt_BR.txt") == (ROUTE, "some.dotted.key", "pt_BR")
        @test entry_for("$ROUTE/welcome/en-GB.txt") == (ROUTE, "welcome", "en-GB")
        # any other filename is itself the key of a locale-less entry
        @test entry_for("admin/site_settings/title.txt") == ("admin/site_settings", "title", nothing)
        @test entry_for("admin/site_settings/some.dotted.key.txt") == ("admin/site_settings", "some.dotted.key", nothing)
        # a flag is addressed by its id, and any other name is a flag to create
        @test entry_for("$FLAGS/1001.json") == (FLAGS, "1001", nothing)
        @test entry_for("$FLAGS/spam-link.json") == (FLAGS, "spam-link", nothing)

        # the form/JSON name is the singular of the route's last segment
        @test singular(ROUTE) == "site_text"
        @test singular("admin/site_settings") == "site_setting"

        mktempdir() do dir
            cd(dir) do
                # routes are declared by entry files or bare dotfiles; content
                # outside admin/ (like the package itself) is out of scope
                mkpath("$ROUTE/one.key"); write("$ROUTE/one.key/en.txt", "x")
                mkpath("admin/mock_things"); write("admin/mock_things/.gitkeep", "")
                mkpath("src"); write("src/pkg.jl", "x")
                @test config_routes() == [ROUTE, "admin/mock_things"]
                @test existing_files(ROUTE, "en") == Dict("one.key" => "$ROUTE/one.key/en.txt")
                @test isempty(existing_files(ROUTE, "fr"))
                @test isempty(existing_files(ROUTE, nothing))
            end
        end
    end

    @testset "admin API client" begin
        empty!(state)
        en()["one.key"] = "hello"
        en()["guidelines_topic.body"] = "## Guidelines\n"
        fr()["one.key"] = "bonjour"

        @test available_locales(client) == ["en", "fr", "pt_BR"]

        @test sort(configured_keys(client, ROUTE; locale = "en")) == ["guidelines_topic.body", "one.key"]
        @test configured_keys(client, ROUTE; locale = "fr") == ["one.key"]
        @test_throws HTTP.StatusError configured_keys(client, ROUTE)  # locale required
        @test get_value(client, ROUTE, "one.key"; locale = "en") == "hello"
        @test get_value(client, ROUTE, "one.key"; locale = "fr") == "bonjour"

        set_value!(client, ROUTE, "one.key", "changed & escaped=safely\n"; locale = "en")
        @test en()["one.key"] == "changed & escaped=safely\n"
        @test LAST_PUT_LOCALE[] == "en"  # required by the site texts API

        reset_value!(client, ROUTE, "one.key"; locale = "en")
        @test !haskey(en(), "one.key")
        @test fr()["one.key"] == "bonjour"
    end

    @testset "configured_keys follows pagination" begin
        empty!(state)
        for i in 1:(3PAGE_SIZE + 1)  # 4 pages, the last one partial
            en()["key.$i"] = "value $i"
        end
        @test sort(configured_keys(client, ROUTE; locale = "en")) == sort!(collect(keys(en())))
    end

    @testset "pull! mirrors every locale of the live state" begin
        empty!(state)
        empty!(things)
        en()["one.key"] = "v1 header"
        en()["added.body"] = "a newly-overridden entry"
        en()["doc.key"] = "markdown content"
        fr()["one.key"] = "entête v1"
        things["thing.a"] = "a value"

        mktempdir() do dir
            cd(dir) do
                # a bare .gitkeep is all a route needs
                mkpath(ROUTE); write("$ROUTE/.gitkeep", "")
                mkpath("admin/mock_things"); write("admin/mock_things/.gitkeep", "")
                mkpath("$ROUTE/one.key"); write("$ROUTE/one.key/en.txt", "stale value")
                mkpath("$ROUTE/doc.key"); write("$ROUTE/doc.key/en.md", "markdown content")
                mkpath("$ROUTE/removed.key"); write("$ROUTE/removed.key/en.txt", "no longer overridden")

                pull!(client)

                @test read("$ROUTE/one.key/en.txt", String) == "v1 header"
                @test read("$ROUTE/one.key/fr.txt", String) == "entête v1"  # all locales, unprompted
                @test read("$ROUTE/doc.key/en.md", String) == "markdown content" # extension preserved
                @test read("$ROUTE/added.body/en.txt", String) == "a newly-overridden entry"
                # a removed entry loses its file and its emptied key directory
                @test !isdir("$ROUTE/removed.key")
                # dotfiles are not mirror content and survive untouched
                @test isfile("$ROUTE/.gitkeep")
                @test sort(readdir(ROUTE)) == [".gitkeep", "added.body", "doc.key", "one.key"]
                # the locale-less route mirrors flat files
                @test read("admin/mock_things/thing.a.txt", String) == "a value"
            end
        end
    end

    @testset "flags" begin
        empty!(flags)
        flags[1001] = copy(SPAM_LINK)

        # only custom flags are entries: keyed by id, valued by the canonical
        # JSON of their settable fields
        @test entries(client, FLAGS) == ["1001" => SPAM_LINK_FILE]
        @test JSON.parse(SPAM_LINK_FILE) == SPAM_LINK

        mktempdir() do dir
            cd(dir) do
                mkpath(FLAGS); write("$FLAGS/.gitkeep", "")
                write("$FLAGS/1001.json", "stale")
                pull!(client)
                @test read("$FLAGS/1001.json", String) == SPAM_LINK_FILE
                @test sort(readdir(FLAGS)) == [".gitkeep", "1001.json"]

                # an id-named file updates that flag; any other name creates one
                apply!(client, ["$FLAGS/1001.json" => JSON.json(merge(SPAM_LINK, Dict("enabled" => false))),
                                "$FLAGS/off-topic-link.json" => JSON.json(merge(SPAM_LINK, Dict("name" => "Off-topic link")))])
                @test flags[1001]["enabled"] == false
                @test flags[1002]["name"] == "Off-topic link"

                # the following pull re-files the new flag under its assigned id
                write("$FLAGS/off-topic-link.json", "as committed")
                pull!(client)
                @test sort(readdir(FLAGS)) == [".gitkeep", "1001.json", "1002.json"]
                @test JSON.parse(read("$FLAGS/1002.json", String))["name"] == "Off-topic link"

                # deleting the file deletes the flag
                apply!(client, ["$FLAGS/1002.json" => nothing])
                @test !haskey(flags, 1002)
                # as does an update to an id the site doesn't have
                @test_throws HTTP.StatusError apply!(client, ["$FLAGS/1234.json" => SPAM_LINK_FILE])
            end
        end
    end

    @testset "posts" begin
        @test post_for("t/faq-guidelines/5/en.md") == (5, "en")
        @test post_for("t/some-slug/5/pt_BR") == (5, "pt_BR")
        @test_throws ErrorException post_for("t/faq-guidelines/5.md")
        @test_throws ErrorException post_for("t/5/en.md")
        @test_throws ErrorException post_for("t/faq-guidelines/five/en.md")
        @test_throws ErrorException post_for("t/faq-guidelines/5/3.md")
        # only the post itself is supported; other locales await translations
        @test topic_for("t/faq-guidelines/5/en.md", "en") == 5
        @test_throws ErrorException topic_for("t/faq-guidelines/5/fr.md", "en")

        empty!(POSTS_BY_ID)
        POSTS_BY_ID[11] = Dict("id" => 11, "topic_id" => 5, "post_number" => 1, "raw" => "Be kind.")
        POSTS_BY_ID[42] = Dict("id" => 42, "topic_id" => 5, "post_number" => 3, "raw" => "A reply")
        @test get_post(client, 5)["id"] == 11

        mktempdir() do dir
            cd(dir) do
                # the files declare which posts are mirrored; a new one may be empty
                mkpath("t/faq-guidelines/5")
                write("t/faq-guidelines/5/en.md", "")
                pull!(client)
                @test read("t/faq-guidelines/5/en.md", String) == "Be kind.\n"

                # an edit finds the post's id, and round-trips through the pull
                withenv("GITHUB_SHA" => "abc123", "GITHUB_REPOSITORY" => "org/repo", "GITHUB_SERVER_URL" => nothing) do
                    apply!(client, ["t/faq-guidelines/5/en.md" => "Be kind.\n\nAnd curious.\n"])
                end
                @test POSTS_BY_ID[11]["raw"] == "Be kind.\n\nAnd curious."
                @test POSTS_BY_ID[42]["raw"] == "A reply"
                @test LAST_EDIT_REASON[] == "https://github.com/org/repo/commit/abc123"
                write("t/faq-guidelines/5/en.md", "Be kind.\n\nAnd curious.\n")
                pull!(client)
                @test read("t/faq-guidelines/5/en.md", String) == "Be kind.\n\nAnd curious.\n"

                # a translation is refused before anything is sent
                @test_throws ErrorException apply!(client, ["t/faq-guidelines/5/fr.md" => "Soyez gentils."])
                @test POSTS_BY_ID[11]["raw"] == "Be kind.\n\nAnd curious."

                # a post that doesn't exist is an error, not a creation
                @test_throws HTTP.StatusError apply!(client, ["t/nope/6/en.md" => "x"])
                mkpath("t/faq-guidelines/6"); write("t/faq-guidelines/6/en.md", "")
                @test_throws HTTP.StatusError pull!(client)
            end
        end
    end

    @testset "file_changes" begin
        mktempdir() do dir
            cd(dir) do
                git("init", "-q"); git("config", "user.name", "test"); git("config", "user.email", "t@t")
                mkpath("$ROUTE/one.key")
                write("$ROUTE/one.key/en.txt", "v1")
                write("$ROUTE/.gitkeep", "")
                write("README.md", "root files are ignored")
                mkpath(".github"); write(".github/dotdirs-are-ignored.txt", "x")
                mkpath("src"); write("src/pkg.jl", "# v1")
                git("add", "-A"); git("commit", "-qm", "c1")
                c1 = git("rev-parse", "HEAD")

                write("$ROUTE/one.key/en.txt", "v2")
                mkpath("$ROUTE/two.key"); write("$ROUTE/two.key/en.txt", "new")
                write("src/pkg.jl", "# v2")  # outside admin/: never synced
                git("add", "-A"); git("commit", "-qm", "c2")

                # contents are read from the working tree, i.e. the range tip
                @test sort(file_changes("$c1..HEAD"); by = first) ==
                      ["$ROUTE/one.key/en.txt" => "v2", "$ROUTE/two.key/en.txt" => "new"]

                rm("$ROUTE/two.key"; recursive = true)
                git("add", "-A"); git("commit", "-qm", "c3")
                c3 = git("rev-parse", "HEAD")

                # two.key was added then deleted, so it nets out of the full span
                @test file_changes("$c1..$c3") == ["$ROUTE/one.key/en.txt" => "v2"]
                @test file_changes("HEAD~1..HEAD") == ["$ROUTE/two.key/en.txt" => nothing]

                # adding or deleting a post's file only starts or stops mirroring it
                mkpath("t/faq/5"); mkpath("t/faq/6"); write("t/faq/5/en.md", ""); write("t/faq/6/en.md", "six")
                git("add", "-A"); git("commit", "-qm", "c4")
                @test file_changes("HEAD~1..HEAD") == []
                write("t/faq/5/en.md", "edited"); rm("t/faq/6/en.md")
                git("add", "-A"); git("commit", "-qm", "c5")
                @test file_changes("HEAD~1..HEAD") == ["t/faq/5/en.md" => "edited"]
            end
        end
    end

    @testset "apply!" begin
        empty!(state)
        en()["one.key"] = "old"
        en()["gone.key"] = "x"
        apply!(client, ["$ROUTE/one.key/en.txt" => "new value",
                        "$ROUTE/gone.key/en.txt" => nothing])
        @test en() == Dict("one.key" => "new value")
        @test LAST_PUT_LOCALE[] == "en"  # derived from the filename
    end
end

close(server)

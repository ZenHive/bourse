defmodule Bourse.ExchangeGeneratorTest do
  @moduledoc "Tests for the Bourse.Exchange generator macro (Tasks 6 + 9)."

  use ExUnit.Case, async: true

  alias Bourse.Exchanges.Loader
  alias Bourse.TestExchange.Binance
  alias Bourse.TestExchange.Bybit
  alias Bourse.Unified

  describe "generated module loading" do
    @generated_module Bourse.TestExchange.Reloadable

    setup do
      :code.purge(@generated_module)
      :code.delete(@generated_module)

      on_exit(fn ->
        :code.purge(@generated_module)
        :code.delete(@generated_module)
      end)
    end

    test "replaces an already-loaded generated module without redefinition warnings" do
      Loader.create(
        @generated_module,
        quote do
          def version, do: :first
        end,
        Macro.Env.location(__ENV__)
      )

      module = Module.concat([Bourse, TestExchange, "Reloadable"])
      assert module.version() == :first

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Loader.create(
            @generated_module,
            quote do
              def version, do: :second
            end,
            Macro.Env.location(__ENV__)
          )
        end)

      assert module.version() == :second
      refute warning =~ "redefining module"
    end
  end

  describe "generated raw endpoint argument guard" do
    test "rejects a keyword list in the params position" do
      exchange = Bourse.Exchange.new!("bybit")

      assert_raise ArgumentError,
                   "expected raw endpoint arguments: (exchange, params_map, opts); " <>
                     "received a keyword list in the params position",
                   fn ->
                     Bourse.Bybit.public_get_v5_market_tickers(exchange, params: %{"category" => "spot"})
                   end
    end
  end

  describe "endpoint route identity" do
    test "every authored route has a unique sections/method/path identity per venue" do
      for venue <- Bourse.Registry.exchanges() do
        module = Bourse.Registry.module_for(venue)
        endpoints = module.__endpoints__()
        identities = Enum.map(endpoints, &Unified.endpoint_id/1)

        assert Enum.all?(identities, &is_binary/1), "#{venue} has an endpoint without a route identity"

        duplicates =
          identities
          |> Enum.frequencies()
          |> Enum.filter(fn {_identity, count} -> count > 1 end)

        assert duplicates == [], "#{venue} has duplicate route identities: #{inspect(duplicates)}"

        for {endpoint, identity} <- Enum.zip(endpoints, identities) do
          expected = Enum.join(endpoint.sections ++ [Atom.to_string(endpoint.method), endpoint.path], "/")
          assert identity == expected
        end
      end
    end

    test "HTTP verbs distinguish Binance FAPI order routes" do
      identities =
        Bourse.Binance.__endpoints__()
        |> Enum.filter(&(&1.sections == ["fapiPrivate"] and &1.path == "order"))
        |> Map.new(&{&1.method, Unified.endpoint_id(&1)})

      assert identities == %{
               delete: "fapiPrivate/delete/order",
               get: "fapiPrivate/get/order",
               post: "fapiPrivate/post/order",
               put: "fapiPrivate/put/order"
             }
    end
  end

  describe "Bybit introspection" do
    test "__id__ returns exchange ID" do
      assert Bybit.__id__() == "bybit"
    end

    test "__name__ returns exchange name" do
      assert Bybit.__name__() == "Bybit"
    end

    test "__spec__ returns lean spec without api key" do
      spec = Bybit.__spec__()
      assert is_map(spec)
      refute Map.has_key?(spec, "api")
    end

    test "__spec__ contains expected metadata keys" do
      spec = Bybit.__spec__()
      assert Map.has_key?(spec, "rateLimit")
      assert Map.has_key?(spec, "has")
      assert Map.has_key?(spec, "urls")
      assert Map.has_key?(spec, "exceptions")
      assert Map.has_key?(spec, "requiredCredentials")
    end

    test "__features__ returns capabilities map" do
      features = Bybit.__features__()
      assert is_map(features)
      assert features == Bourse.Spec.load!("bybit")["capabilities"]["has"]
      assert Enum.all?(features, fn {_method, declaration} -> declaration in [true, false, "emulated"] end)
      assert features["fetchTicker"] == true
    end

    test "__endpoints__ returns list of endpoint configs" do
      endpoints = Bybit.__endpoints__()
      assert is_list(endpoints)
      assert length(endpoints) > 300
    end

    test "endpoint configs have required keys" do
      endpoint = hd(Bybit.__endpoints__())
      assert Map.has_key?(endpoint, :name)
      assert Map.has_key?(endpoint, :method)
      assert Map.has_key?(endpoint, :path)
      assert Map.has_key?(endpoint, :sections)
      assert Map.has_key?(endpoint, :weight)
      assert Map.has_key?(endpoint, :authenticated)
    end

    test "authenticated flag matches spec authenticated_sections" do
      # Bybit: authenticated_sections = ["private"]
      endpoints = Bybit.__endpoints__()
      private_ep = Enum.find(endpoints, &(hd(&1.sections) == "private"))
      public_ep = Enum.find(endpoints, &(hd(&1.sections) == "public"))

      assert private_ep.authenticated
      refute public_ep.authenticated
    end

    test "endpoint method values are atoms" do
      methods =
        Bybit.__endpoints__()
        |> Enum.map(& &1.method)
        |> Enum.uniq()
        |> Enum.sort()

      assert Enum.all?(methods, &is_atom/1)
      assert :get in methods
      assert :post in methods
    end

    test "sections include public and private" do
      section_sets =
        Bybit.__endpoints__()
        |> Enum.map(& &1.sections)
        |> Enum.uniq()

      assert ["public"] in section_sets
      assert ["private"] in section_sets
    end
  end

  describe "Binance introspection" do
    test "__id__ returns exchange ID" do
      assert Binance.__id__() == "binance"
    end

    test "__name__ returns exchange name" do
      assert Binance.__name__() == "Binance"
    end

    test "has more section groups than Bybit" do
      binance_sections =
        Binance.__endpoints__()
        |> Enum.map(& &1.sections)
        |> Enum.uniq()

      bybit_sections =
        Bybit.__endpoints__()
        |> Enum.map(& &1.sections)
        |> Enum.uniq()

      assert length(binance_sections) > length(bybit_sections)
    end

    test "has significantly more endpoints than Bybit" do
      assert length(Binance.__endpoints__()) >
               length(Bybit.__endpoints__())
    end

    test "includes sapi section" do
      section_sets =
        Binance.__endpoints__()
        |> Enum.map(& &1.sections)
        |> Enum.uniq()

      assert ["sapi"] in section_sets
    end

    test "complex weights are normalized to numbers" do
      weights = Enum.map(Binance.__endpoints__(), & &1.weight)
      assert Enum.all?(weights, &is_number/1)
    end
  end

  describe "Descripex wiring" do
    test "Bybit has __api__/0 returning list from Descripex" do
      assert is_list(Bybit.__api__())
    end

    test "Bybit has __api__/1 from Descripex" do
      assert is_nil(Bybit.__api__(:nonexistent))
    end

    test "Binance has __api__/0 returning list from Descripex" do
      assert is_list(Binance.__api__())
    end

    test "__api__/0 returns empty list (no api() declarations yet)" do
      assert Bybit.__api__() == []
    end
  end

  describe "external resource tracking" do
    test "Bybit tracks spec file for recompilation" do
      attrs = Bybit.__info__(:attributes)
      external_resources = Keyword.get_values(attrs, :external_resource)
      resources = List.flatten(external_resources)

      assert Enum.any?(resources, &String.ends_with?(&1, "bybit.json"))
      assert Enum.any?(resources, &String.ends_with?(&1, "authored/bybit.json"))
    end

    test "Binance tracks spec file for recompilation" do
      attrs = Binance.__info__(:attributes)
      external_resources = Keyword.get_values(attrs, :external_resource)
      resources = List.flatten(external_resources)

      assert Enum.any?(resources, &String.ends_with?(&1, "binance.json"))
    end
  end

  describe "build_endpoint_configs/1" do
    test "transforms standard 2-level tree into flat list" do
      api_tree = %{
        "public" => %{
          "get" => %{
            "v5/market/tickers" => 5
          }
        },
        "private" => %{
          "post" => %{
            "v5/order/create" => 2.5
          }
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)
      assert length(configs) == 2

      ticker = Enum.find(configs, &(&1.path == "v5/market/tickers"))
      assert ticker.name == :public_get_v5_market_tickers
      assert ticker.method == :get
      assert ticker.sections == ["public"]
      assert ticker.weight == 5

      order = Enum.find(configs, &(&1.path == "v5/order/create"))
      assert order.name == :private_post_v5_order_create
      assert order.method == :post
      assert order.sections == ["private"]
      assert order.weight == 2.5
    end

    test "handles deep nesting (BingX pattern)" do
      api_tree = %{
        "spot" => %{
          "v1" => %{
            "private" => %{
              "get" => %{"account/balance" => 2},
              "post" => %{"order/create" => 1}
            }
          }
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)
      assert length(configs) == 2

      balance = Enum.find(configs, &(&1.path == "account/balance"))
      assert balance.name == :spot_v1_private_get_account_balance
      assert balance.method == :get
      assert balance.sections == ["spot", "v1", "private"]
      assert balance.weight == 2
    end

    test "handles intermediate sections (Gate pattern)" do
      api_tree = %{
        "public" => %{
          "delivery" => %{
            "get" => %{"{settle}/candlesticks" => 1}
          },
          "spot" => %{
            "get" => %{"currency_pairs" => 1}
          }
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)
      assert length(configs) == 2

      candles = Enum.find(configs, &(&1.path == "{settle}/candlesticks"))
      assert candles.name == :public_delivery_get_settle__candlesticks
      assert candles.sections == ["public", "delivery"]
    end

    test "traverses 'options' as section name, not HTTP verb (Gate pattern)" do
      # Regression: "options" was in @http_methods, causing Gate's options
      # trading section to be treated as an HTTP OPTIONS leaf instead of
      # being traversed as an API tree branch.
      api_tree = %{
        "public" => %{
          "options" => %{
            "get" => %{
              "contracts" => 1,
              "underlyings" => 1
            }
          }
        },
        "private" => %{
          "options" => %{
            "post" => %{"orders" => 1},
            "delete" => %{"orders/{order_id}" => 1},
            "get" => %{"accounts" => 1}
          }
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)
      names = Enum.map(configs, & &1.name)

      # Should produce section-traversed names, not bogus :public_options_get
      assert :public_options_get_contracts in names
      assert :public_options_get_underlyings in names
      assert :private_options_post_orders in names
      assert :private_options_delete_orders__order_id in names
      assert :private_options_get_accounts in names
      assert length(configs) == 5

      # Verify sections include "options" as a section, not as the HTTP method
      contracts = Enum.find(configs, &(&1.name == :public_options_get_contracts))
      assert contracts.sections == ["public", "options"]
      assert contracts.method == :get
    end

    test "handles array-style endpoints (Alpaca pattern)" do
      api_tree = %{
        "market" => %{
          "private" => %{
            "get" => ["v1/corporate-actions", "v1/forex/rates"]
          }
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)
      assert length(configs) == 2

      actions = Enum.find(configs, &(&1.path == "v1/corporate-actions"))
      assert actions.name == :market_private_get_v1_corporate_actions
      assert actions.method == :get
      assert actions.sections == ["market", "private"]
      assert actions.weight == 1
    end

    test "normalizes complex weight objects" do
      api_tree = %{
        "public" => %{
          "get" => %{
            "depth" => %{"byLimit" => [[100, 1], [500, 5]], "cost" => 1},
            "ticker" => 0.4
          }
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)

      depth = Enum.find(configs, &(&1.path == "depth"))
      assert depth.weight == 1

      ticker = Enum.find(configs, &(&1.path == "ticker"))
      assert ticker.weight == 0.4
    end

    test "returns empty list for empty tree" do
      assert Bourse.Exchange.build_endpoint_configs(%{}) == []
    end

    test "sanitizes path characters in function names" do
      api_tree = %{
        "public" => %{
          "get" => %{
            "api/v3/my-endpoint.json" => 1
          }
        }
      }

      [config] = Bourse.Exchange.build_endpoint_configs(api_tree)
      assert config.name == :public_get_api_v3_my_endpoint_json
    end

    test "skips non-map, non-list endpoint values" do
      api_tree = %{
        "public" => %{
          "get" => "not_a_map_or_list"
        }
      }

      configs = Bourse.Exchange.build_endpoint_configs(api_tree)
      assert configs == []
    end

    test "authenticated flag driven by structure.authenticated_sections" do
      api_tree = %{
        "public" => %{"get" => %{"tickers" => 1}},
        "private" => %{"post" => %{"order" => 1}},
        "fapiPrivate" => %{"get" => %{"account" => 1}}
      }

      configs =
        Bourse.Exchange.build_endpoint_configs(api_tree, %{}, ["private", "fapiPrivate"])

      public = Enum.find(configs, &(&1.path == "tickers"))
      private = Enum.find(configs, &(&1.path == "order"))
      fapi = Enum.find(configs, &(&1.path == "account"))

      refute public.authenticated
      assert private.authenticated
      assert fapi.authenticated
    end

    test "nested authenticated_sections entries match their full section path" do
      api_tree = %{
        "contract" => %{
          "public" => %{"get" => %{"api/v1/contract_contract_info" => 1}},
          "private" => %{"get" => %{"api/v1/contract_api_trading_status" => 1}}
        },
        "spot" => %{
          "private" => %{"get" => %{"v1/account/accounts" => 1}}
        }
      }

      configs =
        Bourse.Exchange.build_endpoint_configs(api_tree, %{}, [
          "contract.private",
          "spot.private"
        ])

      public = Enum.find(configs, &(&1.sections == ["contract", "public"]))
      contract_private = Enum.find(configs, &(&1.sections == ["contract", "private"]))
      spot_private = Enum.find(configs, &(&1.sections == ["spot", "private"]))

      refute public.authenticated
      assert contract_private.authenticated
      assert spot_private.authenticated
    end

    test "authenticated flag defaults to false when authenticated_sections omitted" do
      api_tree = %{"private" => %{"post" => %{"order" => 1}}}

      [config] = Bourse.Exchange.build_endpoint_configs(api_tree)
      refute config.authenticated
    end
  end

  describe "catalog-wide authenticated_sections invariant" do
    # Task 284: an authored `authenticated_sections` entry the generator fails to
    # match is SILENT — the endpoints materialize `authenticated: false` and
    # dispatch unsigned rather than failing loudly. That is how htx
    # `contract.private` / `spot.private` (and four other venues) went unsigned.
    #
    # The two sides are independent on purpose: the authored intent is read from
    # the on-disk spec via `Bourse.Spec.load!/1` (the generated module's
    # `__spec__/0` is the LEAN runtime describe and carries no "auth" key, so
    # reading it here would make this test vacuously green), and the graded value
    # is the generated `authenticated` flag. An entry designates a section path,
    # dotted for nested sections — split on "." rather than reusing the
    # generator's matcher, which is the code under test.
    setup do
      authored =
        for id <- Bourse.Registry.exchanges(),
            mod = Bourse.Registry.module_for(id),
            not is_nil(mod),
            entry <- get_in(Bourse.Spec.load!(id), ["auth", "authenticated_sections"]) || [],
            do: {id, mod, entry, String.split(entry, ".")}

      # Guard the guard: if the spec surface ever moves again, this test must go
      # red rather than silently iterate nothing.
      assert authored != [], "no authenticated_sections entries found — invariant is vacuous"

      %{authored: authored}
    end

    test "every endpoint under an authored section is generated authenticated", %{
      authored: authored
    } do
      unsigned =
        for {id, mod, entry, target} <- authored,
            endpoint <- mod.__endpoints__(),
            List.starts_with?(endpoint.sections, target),
            not endpoint.authenticated,
            do: {id, entry, endpoint.name}

      assert unsigned == [],
             "endpoints under an authored authenticated_sections entry that dispatch " <>
               "UNSIGNED (#{length(unsigned)} total): #{inspect(Enum.take(unsigned, 10))}"
    end

    test "every authored section designates at least one generated endpoint", %{
      authored: authored
    } do
      dead_entries =
        for {id, mod, entry, target} <- authored,
            not Enum.any?(mod.__endpoints__(), &List.starts_with?(&1.sections, target)),
            do: {id, entry}

      assert dead_entries == [],
             "authenticated_sections entries that designate NO endpoint " <>
               "(#{length(dead_entries)} total): #{inspect(dead_entries)}"
    end

    # Task 292: the MIRROR of the 284 direction above. An endpoint section that
    # IS private but that no authored entry covers materializes
    # `authenticated: false` and dispatches UNSIGNED, silently — the omission
    # looks like completed authoring rather than a gap.
    #
    # The rule that distinguishes "must be covered" from "legitimately
    # unauthenticated", since the section path alone cannot decide it:
    #
    #   1. The venue must have a NON-EMPTY authored list. A venue with no private
    #      sections has no authentication intent to check.
    #   2. Within such a venue, a section path carrying a "private" marker is
    #      taken as intent-to-authenticate. That marker is the venue author's own
    #      naming, and on a venue that HAS authored auth it is a gap, not a
    #      coincidence. The pinned compatibility implementations for kucoin
    #      `utaPrivate` and coinspot `v2.private` both sign those sections.
    #
    # The graded value is the GENERATED `authenticated` flag, not a re-derived
    # "is this section covered?" match. Re-implementing the generator's matcher
    # here would grade the code under test against a copy of itself, and a copy
    # that is more permissive than `section_authenticated?/2` (which matches the
    # exact dotted path or the TOP section only, never an intermediate prefix)
    # would call a section "covered" while the generator left it unsigned.
    test "every private endpoint section on an auth-authored venue is generated authenticated" do
      unsigned =
        for id <- Bourse.Registry.exchanges(),
            mod = Bourse.Registry.module_for(id),
            not is_nil(mod),
            authored = get_in(Bourse.Spec.load!(id), ["auth", "authenticated_sections"]) || [],
            authored != [],
            endpoint <- mod.__endpoints__(),
            private_section?(endpoint.sections),
            not endpoint.authenticated,
            uniq: true,
            do: {id, Enum.join(endpoint.sections, ".")}

      assert unsigned == [],
             "private endpoint sections on venues WITH authored auth that dispatch " <>
               "UNSIGNED (#{length(unsigned)} total): #{inspect(Enum.take(unsigned, 10))}"
    end
  end

  describe "compute_url_prefixes/2" do
    test "extracts path prefix from url_prefix using URI fallback (OKX pattern)" do
      # OKX: urls.api has only "rest" key, no per-section entries.
      # Falls back to URI path extraction since section_base_url returns nil.
      spec = %{
        "raw" => %{
          "describe" => %{"urls" => %{"api" => %{"rest" => "https://www.okx.com"}}},
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://www.okx.com/api/v5/"}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "www.okx.com")
      assert prefixes["public"] == "/api/v5/"
    end

    test "extracts path prefix by stripping base URL (Gate pattern)" do
      # Gate: per-section base URLs in urls.api. Prefix = url_prefix minus base_url.
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => %{
                  "spot" => "https://api.gateio.ws/api/v4",
                  "delivery" => "https://api.gateio.ws/api/v4"
                }
              }
            }
          },
          "url_templates" => %{
            "public.spot" => %{"url_prefix" => "https://api.gateio.ws/api/v4/spot/"},
            "public.delivery" => %{"url_prefix" => "https://api.gateio.ws/api/v4/delivery/"}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public.spot"] == "/spot/"
      assert prefixes["public.delivery"] == "/delivery/"
    end

    test "handles multiple hostnames per section (KuCoin pattern)" do
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => "https://api.kucoin.com",
                "futuresPublic" => "https://api-futures.kucoin.com"
              }
            }
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://api.kucoin.com/api/v3/"},
            "futuresPublic" => %{"url_prefix" => "https://api-futures.kucoin.com/api/v1/"}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public"] == "/api/v3/"
      assert prefixes["futuresPublic"] == "/api/v1/"
    end

    test "inherits prefix for private sections from public" do
      spec = %{
        "raw" => %{
          "describe" => %{"urls" => %{"api" => %{"rest" => "https://www.okx.com"}}},
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://www.okx.com/api/v5/"},
            "private" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "www.okx.com")
      assert prefixes["public"] == "/api/v5/"
      assert prefixes["private"] == "/api/v5/"
    end

    test "inherits nested private from nested public (Gate pattern)" do
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => %{"spot" => "https://api.gateio.ws/api/v4"},
                "private" => %{"spot" => "https://api.gateio.ws/api/v4"}
              }
            }
          },
          "url_templates" => %{
            "public.spot" => %{"url_prefix" => "https://api.gateio.ws/api/v4/spot/"},
            "private.spot" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public.spot"] == "/spot/"
      assert prefixes["private.spot"] == "/spot/"
    end

    test "interpolates {hostname} in urls.api before stripping base URL" do
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{"api" => %{"public" => "https://api.{hostname}"}}
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://api.bybit.com/"}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "bybit.com")
      assert prefixes["public"] == "/"
    end

    test "returns empty map when no url_templates in spec" do
      spec = %{"raw" => %{}}
      assert Bourse.Exchange.compute_url_prefixes(spec, "") == %{}
    end

    test "non-private section without url_prefix gets default / (Kraken Futures history)" do
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => "https://futures.kraken.com/derivatives/api/",
                "history" => "https://futures.kraken.com/api/history/"
              }
            }
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://futures.kraken.com/derivatives/api/v3/"},
            "history" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public"] == "/v3/"
      assert prefixes["history"] == "/"
    end

    test "non-private section without url_prefix gets default / (KuCoin broker)" do
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => "https://api.kucoin.com",
                "broker" => "https://api-broker.kucoin.com"
              }
            }
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://api.kucoin.com/api/v3/"},
            "broker" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public"] == "/api/v3/"
      assert prefixes["broker"] == "/"
    end

    test "falls back to URI path when url_prefix host differs from base URL" do
      # url_prefix from a different host than urls.api — falls to URI path extraction
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{"api" => %{"status" => "https://status.example.com"}}
          },
          "url_templates" => %{
            "status" => %{"url_prefix" => "https://different-host.example.com/api/v1/"}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      # Host mismatch triggers URI path fallback: /api/v1/
      assert prefixes["status"] == "/api/v1/"
    end

    test "namespaced private inherits from namespaced public (HTX contract pattern)" do
      # HTX: contract.public has its own prefix (different host than top-level public).
      # contract.private inherits from contract.public, NOT from top-level "public".
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => "https://api.huobi.pro",
                "contract" => %{
                  "public" => "https://api.hbdm.vn",
                  "private" => "https://api.hbdm.vn"
                }
              }
            }
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://api.huobi.pro/v1/"},
            "contract.public" => %{"url_prefix" => "https://api.hbdm.vn/"},
            "contract.private" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "api.huobi.pro")
      assert prefixes["public"] == "/v1/"
      assert prefixes["contract.public"] == "/"
      # contract.private inherits "/" from contract.public, not "/v1/" from public
      assert prefixes["contract.private"] == "/"
    end

    test "stripped suffix inherits from base section (KuCoin utaPrivate pattern)" do
      # KuCoin: utaPrivate has no utaPublic — the public counterpart is just "uta".
      # Must inherit from "uta", not fall back to top-level "public".
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => "https://api.kucoin.com",
                "uta" => "https://api.kucoin.com",
                "utaPrivate" => "https://api.kucoin.com"
              }
            }
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://api.kucoin.com/api/v3/"},
            "uta" => %{"url_prefix" => "https://api.kucoin.com/api/ua/v1/"},
            "utaPrivate" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "api.kucoin.com")
      assert prefixes["public"] == "/api/v3/"
      assert prefixes["uta"] == "/api/ua/v1/"
      # utaPrivate must inherit from "uta" via stripped suffix, not from "public"
      assert prefixes["utaPrivate"] == "/api/ua/v1/"
    end

    test "btcmarkets: url_prefix avoids hostname collision that broke old derivation" do
      # Old bug: "markets" in sample_path matched "markets" in "btcmarkets.net" hostname,
      # corrupting the prefix. New approach reads url_prefix directly — no string splitting.
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => "https://api.btcmarkets.net",
                "private" => "https://api.btcmarkets.net"
              }
            }
          },
          "url_templates" => %{
            "public" => %{"url_prefix" => "https://api.btcmarkets.net/v3/"},
            "private" => %{"url_prefix" => nil}
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public"] == "/v3/"
      assert prefixes["private"] == "/v3/"
    end

    test "Gate flash_swap with url_prefix from extraction" do
      spec = %{
        "raw" => %{
          "describe" => %{
            "urls" => %{
              "api" => %{
                "public" => %{
                  "spot" => "https://api.gateio.ws/api/v4",
                  "flash_swap" => "https://api.gateio.ws/api/v4"
                }
              }
            }
          },
          "url_templates" => %{
            "public.spot" => %{"url_prefix" => "https://api.gateio.ws/api/v4/spot/"},
            "public.flash_swap" => %{
              "url_prefix" => "https://api.gateio.ws/api/v4/flash_swap/"
            }
          }
        }
      }

      prefixes = Bourse.Exchange.compute_url_prefixes(spec, "")
      assert prefixes["public.spot"] == "/spot/"
      assert prefixes["public.flash_swap"] == "/flash_swap/"
    end
  end

  describe "build_endpoint_configs/2 with url_prefixes" do
    test "attaches url_prefix to each endpoint config" do
      api_tree = %{
        "public" => %{"get" => %{"market/tickers" => 1}},
        "private" => %{"post" => %{"trade/order" => 1}}
      }

      prefixes = %{"public" => "/api/v5/", "private" => "/api/v5/"}
      configs = Bourse.Exchange.build_endpoint_configs(api_tree, prefixes)

      ticker = Enum.find(configs, &(&1.path == "market/tickers"))
      assert ticker.url_prefix == "/api/v5/"

      order = Enum.find(configs, &(&1.path == "trade/order"))
      assert order.url_prefix == "/api/v5/"
    end

    test "defaults url_prefix to / when section not in prefixes" do
      api_tree = %{"public" => %{"get" => %{"ticker" => 1}}}
      configs = Bourse.Exchange.build_endpoint_configs(api_tree, %{})

      assert hd(configs).url_prefix == "/"
    end

    test "uses dot-joined sections as prefix lookup key" do
      api_tree = %{
        "public" => %{
          "spot" => %{"get" => %{"tickers" => 1}},
          "delivery" => %{"get" => %{"contracts" => 1}}
        }
      }

      prefixes = %{"public.spot" => "/spot/", "public.delivery" => "/delivery/"}
      configs = Bourse.Exchange.build_endpoint_configs(api_tree, prefixes)

      tickers = Enum.find(configs, &(&1.path == "tickers"))
      assert tickers.url_prefix == "/spot/"

      contracts = Enum.find(configs, &(&1.path == "contracts"))
      assert contracts.url_prefix == "/delivery/"
    end
  end

  describe "generated exchange url_prefix smoke tests" do
    test "OKX public endpoints have /api/v5/ prefix" do
      configs = Bourse.Okx.__endpoints__()
      public_ticker = Enum.find(configs, &(&1.name == :public_get_market_ticker))

      if public_ticker do
        assert public_ticker.url_prefix == "/api/v5/"
      end
    end

    test "Bybit public endpoints have / prefix (no version path)" do
      configs = Bourse.Bybit.__endpoints__()
      tickers = Enum.find(configs, &(&1.name == :public_get_v5_market_tickers))
      assert tickers.url_prefix == "/"
    end
  end

  describe "generated exchange moduledoc (Task 29)" do
    test "build_exchange_moduledoc surfaces spec metadata for Bybit" do
      data = Bourse.Exchange.prepare_generate_data("bybit")
      doc = Bourse.Exchange.build_exchange_moduledoc(data)

      assert doc =~ "Bybit exchange client"
      assert doc =~ "`bybit`"
      assert doc =~ "bybit.com"
      # 4.13.0: bybit's branch_family recipe → header signing (X-BAPI-SIGN).
      assert doc =~ "hmac_sha256_headers"
      assert doc =~ "fetchTicker"
      assert doc =~ "apiKey"
      assert doc =~ "secret"
      assert doc =~ "#{data.doc_meta.endpoint_count} raw REST endpoints"
    end

    test "Bourse.Bybit module carries generated @moduledoc for ExDoc" do
      {:docs_v1, _, _, _, moduledoc, _, _} = Code.fetch_docs(Bourse.Bybit)
      doc = moduledoc["en"]

      assert is_binary(doc)
      assert doc =~ "Bybit exchange client"
      assert doc =~ "bybit.com"
    end
  end

  describe "generated endpoint functions" do
    test "Bybit has a function for every endpoint config" do
      for config <- Bybit.__endpoints__() do
        assert exported?(Bybit, config.name, 3),
               "Missing function: #{config.name}/3"
      end
    end

    test "Binance has a function for every endpoint config" do
      for config <- Binance.__endpoints__() do
        assert exported?(Binance, config.name, 3),
               "Missing function: #{config.name}/3"
      end
    end

    test "generated functions support arity 1, 2, and 3" do
      # Pick the first endpoint from Bybit
      config = hd(Bybit.__endpoints__())

      assert exported?(Bybit, config.name, 1),
             "Missing arity 1 for #{config.name}"

      assert exported?(Bybit, config.name, 2),
             "Missing arity 2 for #{config.name}"

      assert exported?(Bybit, config.name, 3),
             "Missing arity 3 for #{config.name}"
    end

    test "generated function requires %Exchange{} as first argument" do
      config = hd(Bybit.__endpoints__())

      assert_raise FunctionClauseError, fn ->
        apply(Bybit, config.name, ["not_an_exchange", %{}, []])
      end
    end
  end

  describe "generated parse functions (Task 21)" do
    @parse_slots ~w(balance deposit_address market ohlcv order position ticker trade transaction)a

    test "all nine parse_<slot>/2 functions are generated" do
      for slot <- @parse_slots do
        fn_name = :"parse_#{slot}"

        assert exported?(Bybit, fn_name, 2),
               "Missing #{fn_name}/2 on Bybit"

        assert exported?(Bybit, fn_name, 1),
               "Missing #{fn_name}/1 (default opts) on Bybit"
      end
    end

    test "__field_maps__/0 exposes the v4 normalization slots" do
      field_maps = Bybit.__field_maps__()
      assert is_map(field_maps)

      for slot <- @parse_slots do
        assert Map.has_key?(field_maps, Atom.to_string(slot)),
               "field_maps missing #{slot}"
      end
    end

    test "parse_ticker parses a resolved slot into a %Bourse.Ticker{}" do
      # Real bybit ticker field_map: last/close ← lastPrice, bid ← bid1Price (safeNumber).
      assert {:ok, %Bourse.Ticker{last: 102.5, close: 102.5, bid: 101.25}} =
               Bybit.parse_ticker(%{"lastPrice" => "102.5", "bid1Price" => "101.25"})
    end

    test "parse over a list of records returns a list of structs" do
      assert {:ok, [%Bourse.Ticker{last: 1.0}, %Bourse.Ticker{last: 2.0}]} =
               Bybit.parse_ticker([%{"lastPrice" => "1.0"}, %{"lastPrice" => "2.0"}])
    end

    test "parse_market parses a resolved bybit slot into a %Bourse.Market{}" do
      assert {:ok, %Bourse.Market{id: "BTCUSDT", base: "BTC", quote: "USDT"}} =
               Bybit.parse_market(%{
                 "symbol" => "BTCUSDT",
                 "baseCoin" => "BTC",
                 "quoteCoin" => "USDT",
                 "status" => "Trading"
               })
    end

    test "parse_ohlcv consumes branch mappings with market discrimination" do
      row = [1_710_000_000_000, "100", "110", "90", "105", "5.0", "6.0"]

      assert {:ok, %Bourse.OHLCV{timestamp: 1_710_000_000_000, volume: vol_inverse}} =
               Bybit.parse_ohlcv(row, market: %{"inverse" => true})

      assert {:ok, %Bourse.OHLCV{volume: vol_linear}} =
               Bybit.parse_ohlcv(row, market: %{"inverse" => false})

      # Discriminator selects a different volume index per market type.
      assert vol_inverse != vol_linear
    end
  end

  # function_exported?/3 does not load a purged module; a mid-suite catalog
  # regeneration (Loader.create purge+delete) can transiently unload generated
  # modules on a cold _build. Reload before asserting.
  defp exported?(mod, fun, arity) do
    Code.ensure_loaded(mod)
    function_exported?(mod, fun, arity)
  end

  defp private_section?(sections) do
    Enum.any?(sections, &String.contains?(String.downcase(&1), "private"))
  end
end

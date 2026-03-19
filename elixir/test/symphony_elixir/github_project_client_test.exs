defmodule SymphonyElixir.GitHub.ProjectClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.ProjectClient

  @org_project_response %{
    "organization" => %{
      "projectV2" => %{
        "id" => "PVT_org1",
        "field" => %{
          "__typename" => "ProjectV2SingleSelectField",
          "id" => "PVTSSF_field1",
          "options" => [
            %{"id" => "opt_todo", "name" => "Todo"},
            %{"id" => "opt_ip", "name" => "In Progress"},
            %{"id" => "opt_done", "name" => "Done"}
          ]
        }
      }
    },
    "user" => nil
  }

  @user_project_response %{
    "organization" => nil,
    "user" => %{
      "projectV2" => %{
        "id" => "PVT_user1",
        "field" => %{
          "__typename" => "ProjectV2SingleSelectField",
          "id" => "PVTSSF_field2",
          "options" => [
            %{"id" => "opt_todo2", "name" => "Todo"},
            %{"id" => "opt_done2", "name" => "Done"}
          ]
        }
      }
    }
  }

  setup do
    prev_request_fun = Application.get_env(:symphony_elixir, :github_request_fun)

    on_exit(fn ->
      ProjectClient.clear_cache()

      if prev_request_fun do
        Application.put_env(:symphony_elixir, :github_request_fun, prev_request_fun)
      else
        Application.delete_env(:symphony_elixir, :github_request_fun)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "github",
      tracker_api_token: "ghp_test",
      tracker_project_slug: "owner/repo",
      tracker_state_source: "project",
      tracker_project_number: 3,
      tracker_project_status_field: "Status"
    )

    :ok
  end

  defp stub_graphql(response_fn) do
    Application.put_env(:symphony_elixir, :github_request_fun, fn method, url, {_token, body} ->
      if method == :post and String.ends_with?(url, "/graphql") do
        response_fn.(body)
      else
        {:ok, %{status: 404, body: %{}, headers: []}}
      end
    end)
  end

  # -------------------------------------------------------------------------
  # ensure_metadata
  # -------------------------------------------------------------------------

  describe "ensure_metadata/0" do
    test "parses org project response" do
      stub_graphql(fn _body ->
        {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
      end)

      assert {:ok, metadata} = ProjectClient.ensure_metadata()
      assert metadata.project_id == "PVT_org1"
      assert metadata.field_id == "PVTSSF_field1"
      assert metadata.options == %{"todo" => "opt_todo", "in progress" => "opt_ip", "done" => "opt_done"}
    end

    test "falls back to user when org is nil" do
      stub_graphql(fn _body ->
        {:ok, %{status: 200, body: %{"data" => @user_project_response}, headers: []}}
      end)

      assert {:ok, metadata} = ProjectClient.ensure_metadata()
      assert metadata.project_id == "PVT_user1"
      assert metadata.field_id == "PVTSSF_field2"
    end

    test "caches metadata in persistent_term" do
      call_count = :counters.new(1, [:atomics])

      stub_graphql(fn _body ->
        :counters.add(call_count, 1, 1)
        {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
      end)

      assert {:ok, _} = ProjectClient.ensure_metadata()
      assert {:ok, _} = ProjectClient.ensure_metadata()
      assert :counters.get(call_count, 1) == 1
    end

    test "returns error when project not found" do
      stub_graphql(fn _body ->
        {:ok,
         %{
           status: 200,
           body: %{"data" => %{"organization" => nil, "user" => nil}},
           headers: []
         }}
      end)

      assert {:error, :project_not_found} = ProjectClient.ensure_metadata()
    end

    test "returns error when field not found" do
      stub_graphql(fn _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "organization" => %{
                 "projectV2" => %{"id" => "PVT_1", "field" => nil}
               },
               "user" => nil
             }
           },
           headers: []
         }}
      end)

      assert {:error, :status_field_not_found} = ProjectClient.ensure_metadata()
    end

    test "returns error when field is not single select" do
      stub_graphql(fn _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "organization" => %{
                 "projectV2" => %{
                   "id" => "PVT_1",
                   "field" => %{"__typename" => "ProjectV2IterationField"}
                 }
               },
               "user" => nil
             }
           },
           headers: []
         }}
      end)

      assert {:error, :status_field_not_single_select} = ProjectClient.ensure_metadata()
    end

    test "detects duplicate status option names after downcasing" do
      stub_graphql(fn _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => %{
               "organization" => %{
                 "projectV2" => %{
                   "id" => "PVT_1",
                   "field" => %{
                     "__typename" => "ProjectV2SingleSelectField",
                     "id" => "PVTSSF_1",
                     "options" => [
                       %{"id" => "opt_1", "name" => "Todo"},
                       %{"id" => "opt_2", "name" => "todo"}
                     ]
                   }
                 }
               },
               "user" => nil
             }
           },
           headers: []
         }}
      end)

      assert {:error, :duplicate_status_options} = ProjectClient.ensure_metadata()
    end
  end

  # -------------------------------------------------------------------------
  # fetch_project_status_map
  # -------------------------------------------------------------------------

  describe "fetch_project_status_map/0" do
    test "returns issue number to status name map" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "items(first: 100") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "items" => %{
                     "nodes" => [
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 42,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => %{"name" => "Todo"}
                       },
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 99,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => %{"name" => "In Progress"}
                       }
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, map} = ProjectClient.fetch_project_status_map()
      assert map == %{"42" => "Todo", "99" => "In Progress"}
    end

    test "skips DraftIssues and PRs" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "items(first: 100") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "items" => %{
                     "nodes" => [
                       %{
                         "content" => %{"__typename" => "DraftIssue"},
                         "fieldValueByName" => %{"name" => "Todo"}
                       },
                       %{
                         "content" => %{
                           "__typename" => "PullRequest",
                           "number" => 10,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => %{"name" => "Todo"}
                       },
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 42,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => %{"name" => "Done"}
                       }
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, map} = ProjectClient.fetch_project_status_map()
      assert map == %{"42" => "Done"}
    end

    test "filters by repo nameWithOwner" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "items(first: 100") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "items" => %{
                     "nodes" => [
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 42,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => %{"name" => "Todo"}
                       },
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 99,
                           "repository" => %{"nameWithOwner" => "other/repo"}
                         },
                         "fieldValueByName" => %{"name" => "Done"}
                       }
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, map} = ProjectClient.fetch_project_status_map()
      assert map == %{"42" => "Todo"}
    end

    test "matches nameWithOwner case-insensitively" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "items(first: 100") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "items" => %{
                     "nodes" => [
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 42,
                           "repository" => %{"nameWithOwner" => "Owner/Repo"}
                         },
                         "fieldValueByName" => %{"name" => "Todo"}
                       }
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, map} = ProjectClient.fetch_project_status_map()
      assert map == %{"42" => "Todo"}
    end

    test "warns when matching issues found but none have status values" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "items(first: 100") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "node" => %{
                   "items" => %{
                     "nodes" => [
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 42,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => nil
                       },
                       %{
                         "content" => %{
                           "__typename" => "Issue",
                           "number" => 99,
                           "repository" => %{"nameWithOwner" => "owner/repo"}
                         },
                         "fieldValueByName" => nil
                       }
                     ],
                     "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      log =
        capture_log(fn ->
          assert {:ok, map} = ProjectClient.fetch_project_status_map()
          assert map == %{}
        end)

      assert log =~ "2 matching issues found but none have a status value"
    end

    test "paginates through items" do
      stub_graphql(fn %{"query" => query, "variables" => vars} ->
        if String.contains?(query, "items(first: 100") do
          if vars["after"] == nil do
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "node" => %{
                     "items" => %{
                       "nodes" => [
                         %{
                           "content" => %{
                             "__typename" => "Issue",
                             "number" => 1,
                             "repository" => %{"nameWithOwner" => "owner/repo"}
                           },
                           "fieldValueByName" => %{"name" => "Todo"}
                         }
                       ],
                       "pageInfo" => %{"hasNextPage" => true, "endCursor" => "cursor1"}
                     }
                   }
                 }
               },
               headers: []
             }}
          else
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "node" => %{
                     "items" => %{
                       "nodes" => [
                         %{
                           "content" => %{
                             "__typename" => "Issue",
                             "number" => 2,
                             "repository" => %{"nameWithOwner" => "owner/repo"}
                           },
                           "fieldValueByName" => %{"name" => "Done"}
                         }
                       ],
                       "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                     }
                   }
                 }
               },
               headers: []
             }}
          end
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, map} = ProjectClient.fetch_project_status_map()
      assert map == %{"1" => "Todo", "2" => "Done"}
    end
  end

  # -------------------------------------------------------------------------
  # fetch_issue_project_status
  # -------------------------------------------------------------------------

  describe "fetch_issue_project_status/1" do
    test "returns status for issue on project" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "projectItems(first: 50") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "issue" => %{
                     "projectItems" => %{
                       "nodes" => [
                         %{
                           "project" => %{"id" => "PVT_org1"},
                           "fieldValueByName" => %{"name" => "In Progress"}
                         }
                       ]
                     }
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, "In Progress"} = ProjectClient.fetch_issue_project_status("42")
    end

    test "returns nil when issue not on the target project" do
      stub_graphql(fn %{"query" => query} ->
        if String.contains?(query, "projectItems(first: 50") do
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "repository" => %{
                   "issue" => %{
                     "projectItems" => %{
                       "nodes" => [
                         %{
                           "project" => %{"id" => "PVT_other"},
                           "fieldValueByName" => %{"name" => "Done"}
                         }
                       ]
                     }
                   }
                 }
               }
             },
             headers: []
           }}
        else
          {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
        end
      end)

      assert {:ok, nil} = ProjectClient.fetch_issue_project_status("42")
    end
  end

  # -------------------------------------------------------------------------
  # update_project_item_status
  # -------------------------------------------------------------------------

  describe "update_project_item_status/2" do
    test "executes mutation successfully" do
      stub_graphql(fn %{"query" => query} ->
        cond do
          String.contains?(query, "organization") ->
            {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}

          String.contains?(query, "projectItems(first: 50") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "issue" => %{
                       "projectItems" => %{
                         "nodes" => [
                           %{"id" => "PVTI_item1", "project" => %{"id" => "PVT_org1"}}
                         ],
                         "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                       }
                     }
                   }
                 }
               },
               headers: []
             }}

          String.contains?(query, "updateProjectV2ItemFieldValue") ->
            {:ok,
             %{
               status: 200,
               body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_item1"}}}},
               headers: []
             }}

          true ->
            {:ok, %{status: 404, body: %{}, headers: []}}
        end
      end)

      assert :ok = ProjectClient.update_project_item_status("42", "Todo")
    end

    test "returns error when issue not on project" do
      stub_graphql(fn %{"query" => query} ->
        cond do
          String.contains?(query, "organization") ->
            {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}

          String.contains?(query, "projectItems(first: 50") ->
            {:ok,
             %{
               status: 200,
               body: %{
                 "data" => %{
                   "repository" => %{
                     "issue" => %{
                       "projectItems" => %{
                         "nodes" => [],
                         "pageInfo" => %{"hasNextPage" => false, "endCursor" => nil}
                       }
                     }
                   }
                 }
               },
               headers: []
             }}

          true ->
            {:ok, %{status: 404, body: %{}, headers: []}}
        end
      end)

      assert {:error, :issue_not_on_project} = ProjectClient.update_project_item_status("42", "Todo")
    end
  end

  # -------------------------------------------------------------------------
  # clear_cache
  # -------------------------------------------------------------------------

  describe "clear_cache/0" do
    test "removes cached metadata" do
      stub_graphql(fn _body ->
        {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
      end)

      assert {:ok, _} = ProjectClient.ensure_metadata()
      ProjectClient.clear_cache()

      call_count = :counters.new(1, [:atomics])

      stub_graphql(fn _body ->
        :counters.add(call_count, 1, 1)
        {:ok, %{status: 200, body: %{"data" => @org_project_response}, headers: []}}
      end)

      assert {:ok, _} = ProjectClient.ensure_metadata()
      assert :counters.get(call_count, 1) == 1
    end
  end

  # -------------------------------------------------------------------------
  # GraphQL error handling
  # -------------------------------------------------------------------------

  describe "GraphQL error handling" do
    test "HTTP 200 with errors array returns graphql_errors" do
      stub_graphql(fn _body ->
        {:ok,
         %{
           status: 200,
           body: %{"errors" => [%{"message" => "Something went wrong"}]},
           headers: []
         }}
      end)

      assert {:error, {:graphql_errors, [%{"message" => "Something went wrong"}]}} =
               ProjectClient.ensure_metadata()
    end

    test "HTTP non-200 returns github_api_status" do
      stub_graphql(fn _body ->
        {:ok, %{status: 403, body: %{}, headers: []}}
      end)

      assert {:error, {:github_api_status, 403}} = ProjectClient.ensure_metadata()
    end

    test "partial data with errors logs warning but returns data" do
      stub_graphql(fn _body ->
        {:ok,
         %{
           status: 200,
           body: %{
             "data" => @org_project_response,
             "errors" => [%{"message" => "partial error"}]
           },
           headers: []
         }}
      end)

      log =
        capture_log(fn ->
          assert {:ok, metadata} = ProjectClient.ensure_metadata()
          assert metadata.project_id == "PVT_org1"
        end)

      assert log =~ "partial error"
    end
  end
end

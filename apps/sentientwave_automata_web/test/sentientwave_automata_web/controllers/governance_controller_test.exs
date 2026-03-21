defmodule SentientwaveAutomataWeb.GovernanceControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Matrix.Directory

  describe "constitution admin pages" do
    test "renders the constitution overview, detail, and roles pages", %{conn: conn} do
      suffix = System.unique_integer([:positive])

      assert {:ok, member} =
               Directory.upsert_user(%{
                 localpart: "constitution-member-#{suffix}",
                 kind: :person,
                 display_name: "Constitution Member",
                 password: "VerySecurePass123!"
               })

      assert {:ok, role} =
               Governance.create_role(%{
                 "slug" => "constitution-role-#{suffix}",
                 "name" => "Constitution Role",
                 "enabled" => true
               })

      assert {:ok, _assignment} = Governance.assign_role(role.id, member.id, %{})

      assert {:ok, law} =
               Governance.create_law(%{
                 "slug" => "constitution-law-#{suffix}",
                 "name" => "Constitution Law",
                 "markdown_body" => """
                 # Constitution Law

                 This law governs reasoning.
                 """,
                 "law_kind" => "general",
                 "position" => 1
               })

      assert {:ok, proposal} =
               Governance.open_law_proposal(%{
                 "reference" => "LAW-DOC-#{suffix}",
                 "proposal_type" => "amend",
                 "law_id" => law.id,
                 "proposed_slug" => "constitution-law-#{suffix}",
                 "proposed_name" => "Constitution Law",
                 "proposed_markdown_body" => """
                 # Constitution Law

                 This law governs reasoning and voting.
                 """,
                 "voting_scope" => "all_members",
                 "created_by_id" => member.id,
                 "room_id" => "!governance:localhost"
               })

      overview_conn =
        conn
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution")

      overview_body = html_response(overview_conn, 200)
      assert overview_body =~ "Constitution Overview"
      assert overview_body =~ "New Proposal"
      assert overview_body =~ "Manage Roles"
      assert overview_body =~ "Published Laws"

      law_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/laws/#{law.id}")

      law_body = html_response(law_conn, 200)
      assert law_body =~ "Law Detail"
      assert law_body =~ "Constitution Law"

      proposal_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/proposals/#{proposal.id}")

      proposal_body = html_response(proposal_conn, 200)
      assert proposal_body =~ "Proposal Detail"
      assert proposal_body =~ proposal.reference

      roles_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/roles")

      roles_body = html_response(roles_conn, 200)
      assert roles_body =~ "Governance Roles"
      assert roles_body =~ "Create Role"
      assert roles_body =~ "Configured Roles"

      role_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/roles/#{role.id}")

      role_body = html_response(role_conn, 200)
      assert role_body =~ "Role Detail"
      assert role_body =~ "Constitution Role"
    end

    test "renders the proposal creation page for create, amend, and repeal flows", %{conn: conn} do
      create_conn =
        conn
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/proposals/new/create")

      create_body = html_response(create_conn, 200)
      assert create_body =~ "Create Proposal"
      assert create_body =~ "Proposal Draft"

      amend_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/proposals/new/amend", %{"law_id" => "missing-law"})

      amend_body = html_response(amend_conn, 200)
      assert amend_body =~ "Amend Proposal"
      assert amend_body =~ "Context Preview"

      repeal_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/proposals/new/repeal")

      repeal_body = html_response(repeal_conn, 200)
      assert repeal_body =~ "Repeal Proposal"
      assert repeal_body =~ "Matrix voting required"
    end

    test "detail routes redirect safely when records are missing", %{conn: conn} do
      law_conn =
        conn
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/laws/does-not-exist")

      assert redirected_to(law_conn) == "/constitution"

      proposal_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/proposals/does-not-exist")

      assert redirected_to(proposal_conn) == "/constitution"

      role_conn =
        build_conn()
        |> init_test_session(automata_admin_authenticated: true)
        |> get("/constitution/roles/does-not-exist")

      assert redirected_to(role_conn) == "/constitution/roles"
    end
  end
end

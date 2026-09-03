####################################################################
# Church Finance & Congregation Dashboard
#
# Reads finances from the `general_ledger` and `account_balances` views,
# same as the youth fellowship dashboard. Members and Visitors are new
# tabs: Members is about who the congregation is (status, gender,
# sacraments) rather than what they've given — giving history lives
# under General Ledger > Member Contributions instead. Visitors gets
# its own richer set of visuals, including a map built from the
# PostGIS `location` column on the visitors table.
#
# Talks to Postgres via a read-only role (see README for the GRANT
# statements — same pattern as the youth dashboard).
####################################################################

library(shiny)
library(shinydashboard)
library(fresh)
library(DBI)
library(RPostgres)
library(dplyr)
library(DT)
library(plotly)
library(lubridate)
library(scales)
library(leaflet)
library(leaflet.extras2) # provides addEasyprint() for the on-map "export as image" control

## ---- CONFIG ---------------------------------------------------------
DB_HOST <- Sys.getenv("CHURCH_DB_HOST", "localhost")
DB_PORT <- as.integer(Sys.getenv("CHURCH_DB_PORT", "5432"))
DB_NAME <- Sys.getenv("CHURCH_DB_NAME", "church_finance")
DB_USER <- Sys.getenv("CHURCH_DB_USER", "shiny_reader")

DB_PASS <- Sys.getenv("CHURCH_DB_PASS")
if (identical(DB_PASS, "")) {
    stop("CHURCH_DB_PASS is not set — check .env / env_file configuration.")
}

# Optional: without this the Visitor Map tab falls back to Esri's
# key-free basemap rather than failing, so it's not a hard requirement.
CARTO_KEY <- Sys.getenv("CARTO_KEY", "")

## ---- STARTUP DEBUG ----------------------------------------------------
# Prints to the Shiny Server log on every app start, so a fresh log file
# tells you definitively what this process saw — never the password
# itself, just whether it's present and how long it is.
message("---- Church Dashboard starting: ", Sys.time(), " ----")
message("CHURCH_DB_HOST = ", DB_HOST)
message("CHURCH_DB_PORT = ", DB_PORT)
message("CHURCH_DB_NAME = ", DB_NAME)
message("CHURCH_DB_USER = ", DB_USER)
message(
    "CHURCH_DB_PASS is set: ",
    nchar(DB_PASS) > 0,
    " (length ",
    nchar(DB_PASS),
    ")"
)
message(
    "CARTO_KEY is set: ",
    nchar(CARTO_KEY) > 0,
    if (nchar(CARTO_KEY) > 0) paste0(" (length ", nchar(CARTO_KEY), ")") else ""
)

## ---- THEME (fresh) ---------------------------------------------------
my_theme <- create_theme(
    adminlte_color(
        light_blue = "#2C3E50", # sidebar / header
        green = "#2E8B57", # income / active / converted
        red = "#B33A3A", # expense / lapsed
        blue = "#3B6E9E", # neutral / net / male
        orange = "#D98E04", # restricted funds / period stats
        purple = "#6B4C9A" # visitor conversion / secondary accent
    ),
    adminlte_sidebar(
        dark_bg = "#1F2B38",
        dark_hover_bg = "#2C3E50",
        dark_color = "#ECF0F1"
    ),
    adminlte_global(
        content_bg = "#F4F6F7",
        box_bg = "#FFFFFF",
        info_box_bg = "#FFFFFF"
    )
)

## Fixed color maps so the same category reads the same color everywhere
## it appears (member status chart, ledger contributions chart, etc.)
STATUS_COLORS <- c(
    student = "#3B6E9E",
    working = "#2E8B57",
    retired = "#D98E04"
)
GENDER_COLORS <- c(Male = "#3B6E9E", Female = "#B36B9E")
VISITOR_STATUS_COLORS <- c(
    active = "#2E8B57",
    converted = "#6B4C9A",
    lapsed = "#B33A3A"
)

## ---- UI HELPER: a consistently-styled download button ------------------
## Used on every tab so "download what I'm looking at" always looks and
## behaves the same way.
download_btn <- function(id, label = "Download data") {
    div(
        class = "download-row",
        downloadButton(
            id,
            label = label,
            icon = icon("download"),
            class = "btn-download-pretty"
        )
    )
}

## ---- DATA LOADING ------------------------------------------------------
# One connection per refresh, closed immediately after — fine for a
# low-traffic single-user dashboard.

load_data <- function() {
    con <- dbConnect(
        RPostgres::Postgres(),
        host = DB_HOST,
        port = DB_PORT,
        dbname = DB_NAME,
        user = DB_USER,
        password = DB_PASS
    )
    on.exit(dbDisconnect(con))

    ledger <- dbGetQuery(con, "SELECT * FROM general_ledger") |>
        mutate(
            entry_date = as.Date(entry_date),
            flow = case_when(
                category_type == "income" ~ "income",
                category_type == "expense" ~ "expense",
                TRUE ~ "transfer"
            )
        )

    balances <- dbGetQuery(con, "SELECT * FROM account_balances")

    funds_meta <- dbGetQuery(
        con,
        "SELECT name AS fund, description, is_restricted, is_active FROM funds"
    )

    # ---- MEMBERS: added location_text and parsed lat/lng later ----
    members <- dbGetQuery(
        con,
        "
    SELECT
      m.full_name, m.phone_number, g.label AS gender, m.general_area,
      ls.label AS location_status, ms.label AS member_status, m.is_active,
      m.baptism_status, m.confirmation_status,
      fg.name AS fellowship_group,
      m.location_text   -- new: semicolon-separated lat;lon
    FROM members m
    LEFT JOIN genders g ON g.id = m.gender_id
    LEFT JOIN member_statuses ms ON ms.id = m.member_status_id
    LEFT JOIN location_statuses ls ON ls.id = m.location_status_id
    LEFT JOIN fellowship_groups fg ON fg.id = m.fellowship_group_id
    "
    )

    # ---- VISITORS: added location_text and parsed lat/lng later ----
    visitors <- dbGetQuery(
        con,
        "
    SELECT
      v.id, v.full_name, v.phone_number, g.label AS gender, v.general_area,
      ls.label AS location_status, v.how_heard, v.first_visit_date,
      v.visitor_status, v.converted_at, m.full_name AS invited_by,
      v.location_text
    FROM visitors v
    LEFT JOIN genders g ON g.id = v.gender_id
    LEFT JOIN location_statuses ls ON ls.id = v.location_status_id
    LEFT JOIN members m ON m.id = v.invited_by_member_id
    "
    ) |>
        mutate(first_visit_date = as.Date(first_visit_date))

    visitor_visits <- dbGetQuery(
        con,
        "
    SELECT vv.visitor_id, vv.visit_date, fg.name AS fellowship_group
    FROM visitor_visits vv
    LEFT JOIN fellowship_groups fg ON fg.id = vv.fellowship_group_id
    "
    ) |>
        mutate(visit_date = as.Date(visit_date))

    list(
        ledger = ledger,
        balances = balances,
        funds_meta = funds_meta,
        members = members,
        visitors = visitors,
        visitor_visits = visitor_visits
    )
}

## ---- UI ------------------------------------------------------------------

ui <- dashboardPage(
    dashboardHeader(title = "Church Finance"),

    dashboardSidebar(
        sidebarMenu(
            shinydashboard::menuItem(
                "Overview",
                tabName = "overview",
                icon = icon("gauge-high")
            ),
            shinydashboard::menuItem(
                "General Ledger",
                tabName = "ledger",
                icon = icon("book")
            ),
            shinydashboard::menuItem(
                "Funds",
                tabName = "funds",
                icon = icon("layer-group")
            ),
            shinydashboard::menuItem(
                "Members",
                tabName = "members",
                icon = icon("users")
            ),
            shinydashboard::menuItem(
                "Visitors",
                tabName = "visitors",
                icon = icon("person-walking-arrow-right")
            )
        ),
        dateRangeInput(
            "date_range",
            "Date range",
            start = floor_date(Sys.Date() - years(1), "year"),
            end = Sys.Date()
        ),
        actionButton(
            "refresh",
            "Refresh data",
            icon = icon("rotate"),
            style = "margin-left:15px;"
        )
    ),

    dashboardBody(
        use_theme(my_theme),
        tags$head(tags$style(HTML(
            "
      .box { border-top: 3px solid #2C3E50; box-shadow: 0 1px 4px rgba(0,0,0,0.08); }
      .small-box { box-shadow: 0 1px 4px rgba(0,0,0,0.08); }

      .btn-download-pretty {
        background: linear-gradient(135deg, #2E8B57, #3B6E9E);
        color: #ffffff !important;
        border: none;
        border-radius: 999px;
        padding: 7px 18px;
        font-weight: 600;
        font-size: 13px;
        letter-spacing: 0.2px;
        box-shadow: 0 2px 6px rgba(0,0,0,0.15);
        transition: transform 0.15s ease, box-shadow 0.15s ease, opacity 0.15s ease;
      }
      .btn-download-pretty:hover {
        transform: translateY(-1px);
        box-shadow: 0 4px 10px rgba(0,0,0,0.2);
        color: #ffffff !important;
        opacity: 0.95;
      }
      .download-row {
        text-align: right;
        margin-bottom: 12px;
      }
    "
        ))),

        tabItems(
            ## ---- OVERVIEW ----
            tabItem(
                tabName = "overview",
                download_btn("dl_overview", "Download transactions (period)"),
                fluidRow(uiOutput("balance_boxes")),
                fluidRow(
                    valueBoxOutput("total_income"),
                    valueBoxOutput("total_expense"),
                    valueBoxOutput("net_balance")
                ),
                fluidRow(
                    tabBox(
                        width = 12,
                        height = "480px",
                        tabPanel(
                            "Monthly Income vs Expenses",
                            plotlyOutput("monthly_chart", height = "420px")
                        ),
                        tabPanel(
                            "Expenses by Category",
                            plotlyOutput("category_chart", height = "420px")
                        ),
                        tabPanel(
                            'Income by category',
                            plotlyOutput(
                                'category_chart_income',
                                height = '420px'
                            )
                        )
                    )
                )
            ),

            ## ---- GENERAL LEDGER ----
            ## "Ledger" is the raw feed. "Member Contributions" is where giving
            ## history and last-gift date live now — moved here from Members,
            ## which is about who the congregation is, not what they've given.
            tabItem(
                tabName = "ledger",
                tabBox(
                    width = 12,
                    height = "820px",
                    tabPanel(
                        "Ledger",
                        checkboxInput(
                            "show_voided",
                            "Show voided entries (reversal rows)",
                            value = FALSE
                        ),
                        download_btn("dl_ledger", "Download ledger"),
                        DTOutput("ledger_table")
                    ),
                    tabPanel(
                        "Member Contributions",
                        download_btn(
                            "dl_contributions",
                            "Download contributions"
                        ),
                        fluidRow(
                            valueBoxOutput("period_contributions"),
                            valueBoxOutput("contributing_members"),
                            valueBoxOutput("avg_contribution")
                        ),
                        fluidRow(
                            box(
                                width = 12,
                                title = "Total Contributed by Member Status",
                                plotlyOutput(
                                    "contribution_status_chart",
                                    height = "320px"
                                )
                            )
                        ),
                        fluidRow(
                            box(
                                width = 12,
                                title = "Member Contributions & Last Gift",
                                DTOutput("members_contributions_table")
                            )
                        )
                    )
                )
            ),

            ## ---- FUNDS ----
            tabItem(
                tabName = "funds",
                download_btn("dl_funds", "Download fund summary"),
                fluidRow(uiOutput("fund_boxes")),
                fluidRow(
                    tabBox(
                        width = 12,
                        height = "520px",
                        tabPanel(
                            "Income vs Expense by Fund",
                            plotlyOutput("fund_chart", height = "440px")
                        ),
                        tabPanel("Fund Summary", DTOutput("fund_summary_table"))
                    )
                )
            ),

            ## ---- MEMBERS ----
            ## Demographics only: who the congregation is, not what they give.
            ## Added a map tab using location_text.
            tabItem(
                tabName = "members",
                download_btn("dl_members", "Download member roster"),
                fluidRow(
                    valueBoxOutput("total_members"),
                    valueBoxOutput("active_members"),
                    valueBoxOutput("baptized_members"),
                    valueBoxOutput("confirmed_members")
                ),
                fluidRow(
                    tabBox(
                        width = 12,
                        height = "640px",
                        tabPanel(
                            "Status Breakdown",
                            plotlyOutput("member_status_pie", height = "480px")
                        ),
                        tabPanel(
                            "Gender Breakdown",
                            plotlyOutput("member_gender_pie", height = "480px")
                        ),
                        tabPanel(
                            "Member Roster",
                            DTOutput("members_table")
                        ),
                        tabPanel(
                            # NEW: Member Map
                            "Member Map",
                            download_btn(
                                "dl_member_coords",
                                "Download coordinates (CSV)"
                            ),
                            leafletOutput("member_map", height = "560px")
                        )
                    )
                )
            ),

            ## ---- VISITORS ----
            tabItem(
                tabName = "visitors",
                download_btn("dl_visitors", "Download visitor roster"),
                fluidRow(
                    valueBoxOutput("total_visitors"),
                    valueBoxOutput("active_visitors"),
                    valueBoxOutput("conversion_rate")
                ),
                fluidRow(
                    tabBox(
                        width = 12,
                        height = "640px",
                        tabPanel(
                            "New Visitors Over Time",
                            plotlyOutput(
                                "visitors_trend_chart",
                                height = "560px"
                            )
                        ),
                        tabPanel(
                            "Visitor Status",
                            plotlyOutput("visitor_status_pie", height = "560px")
                        ),
                        tabPanel(
                            "How They Heard",
                            plotlyOutput("how_heard_chart", height = "560px")
                        ),
                        tabPanel(
                            "Gender Breakdown",
                            plotlyOutput("visitor_gender_pie", height = "560px")
                        ),
                        tabPanel(
                            "Visitor Map",
                            download_btn(
                                "dl_visitor_coords",
                                "Download coordinates (CSV)"
                            ),
                            leafletOutput("visitor_map", height = "560px")
                        ),
                        tabPanel(
                            "Visitor Roster",
                            DTOutput("visitors_table")
                        )
                    )
                )
            )
        )
    )
)

## ---- SERVER ----------------------------------------------------------------

server <- function(input, output, session) {
    raw <- reactiveVal(load_data())
    observeEvent(input$refresh, raw(load_data()))

    # ---- Financial ledger vs display ledger ----
    # Financial calculations MUST include reversal rows so that a void
    # cancels the original transaction. The display ledger can hide those
    # reversal rows unless the user explicitly asks to see them.
    #
    # `effective_date`: a reversal row is dated whenever it was actually
    # processed, which is often a different month (even a different
    # reporting period) than the transaction it cancels. Grouping or
    # date-filtering by that raw date can separate a void from its
    # original — one lands inside the selected range, the other doesn't —
    # leaving a stray, wrongly-signed bar in whichever period the split
    # half landed in. Pinning a reversal's effective_date back to
    # `voids_entry_date` (the original entry's date, already exposed by
    # the view) keeps every void paired with what it cancels, so it nets
    # to exactly zero regardless of how long after the fact it was voided.
    financial_activity <- reactive({
        raw()$ledger |>
            mutate(effective_date = coalesce(voids_entry_date, entry_date)) |>
            filter(
                effective_date >= input$date_range[1],
                effective_date <= input$date_range[2]
            )
    })

    # Plain entry_date filter, deliberately NOT using effective_date — the
    # raw Ledger table is an audit view, so a reversal should show up on
    # the date it was actually processed, not the date of what it voided.
    ledger_display_range <- reactive({
        raw()$ledger |>
            filter(
                entry_date >= input$date_range[1],
                entry_date <= input$date_range[2]
            )
    })

    ledger_in_range <- reactive({
        df <- ledger_display_range()

        if (!isTRUE(input$show_voided)) {
            df <- df |> filter(!is_reversal)
        }

        df
    })

    # ---- Members data with location_text parsed ----
    members_with_coords <- reactive({
        raw()$members |>
            mutate(
                # Parse "lat;lon" from location_text
                lat = as.numeric(sapply(strsplit(location_text, ";"), `[`, 1)),
                lng = as.numeric(sapply(strsplit(location_text, ";"), `[`, 2))
            )
    })

    # ---- Visitors data with location_text parsed ----
    visitors_with_coords <- reactive({
        raw()$visitors |>
            mutate(
                # Parse "lat;lon" from location_text
                lat = as.numeric(sapply(strsplit(location_text, ";"), `[`, 1)),
                lng = as.numeric(sapply(strsplit(location_text, ";"), `[`, 2))
            )
    })

    ## ==================== OVERVIEW ====================

    output$balance_boxes <- renderUI({
        bal <- raw()$balances
        boxes <- lapply(seq_len(nrow(bal)), function(i) {
            row <- bal[i, ]
            valueBox(
                dollar(row$current_balance, prefix = "KES "),
                subtitle = row$account_name,
                icon = icon(
                    if (
                        grepl(
                            "mpesa|mobile",
                            row$account_name,
                            ignore.case = TRUE
                        )
                    ) {
                        "mobile-screen"
                    } else {
                        "building-columns"
                    }
                ),
                color = if (row$current_balance >= 0) "blue" else "red",
                width = 3
            )
        })
        do.call(fluidRow, boxes)
    })

    output$total_income <- renderValueBox({
        v <- financial_activity() |>
            filter(entry_type == "transaction", flow == "income") |>
            pull(signed_amount) |>
            sum(na.rm = TRUE)
        valueBox(
            dollar(v, prefix = "KES "),
            "Total Income",
            icon = icon("arrow-up"),
            color = "green"
        )
    })

    output$total_expense <- renderValueBox({
        v <- financial_activity() |>
            filter(entry_type == "transaction", flow == "expense") |>
            summarise(total = sum(-signed_amount, na.rm = TRUE)) |>
            pull(total)
        valueBox(
            dollar(v, prefix = "KES "),
            "Total Expenses",
            icon = icon("arrow-down"),
            color = "red"
        )
    })

    output$net_balance <- renderValueBox({
        v <- financial_activity() |>
            filter(entry_type == "transaction") |>
            pull(signed_amount) |>
            sum(na.rm = TRUE)
        valueBox(
            dollar(v, prefix = "KES "),
            "Net (period)",
            icon = icon("scale-balanced"),
            color = if (v >= 0) "blue" else "orange"
        )
    })

    output$monthly_chart <- renderPlotly({
        monthly <- financial_activity() |>
            filter(entry_type == "transaction") |>
            mutate(
                month = floor_date(effective_date, "month"),
                amount = case_when(
                    flow == "income" ~ signed_amount,
                    flow == "expense" ~ -signed_amount,
                    TRUE ~ 0
                )
            ) |>
            group_by(month, flow) |>
            summarise(total = sum(amount, na.rm = TRUE), .groups = "drop")

        p <- ggplot2::ggplot(
            monthly,
            ggplot2::aes(x = month, y = total, fill = flow)
        ) +
            ggplot2::geom_col(position = "dodge") +
            ggplot2::scale_fill_manual(
                values = c(income = "#2E8B57", expense = "#B33A3A")
            ) +
            ggplot2::scale_y_continuous(labels = function(x) {
                dollar(x, prefix = "KES ")
            }) +
            ggplot2::labs(x = NULL, y = NULL, fill = NULL) +
            ggplot2::theme_minimal(base_size = 12)

        ggplotly(p)
    })

    output$category_chart <- renderPlotly({
        by_cat <- financial_activity() |>
            filter(entry_type == "transaction", flow == "expense") |>
            group_by(category_name) |>
            summarise(
                total = sum(-signed_amount, na.rm = TRUE),
                .groups = "drop"
            ) |>
            filter(total != 0) |>
            arrange(desc(total))

        plot_ly(
            by_cat,
            labels = ~category_name,
            values = ~total,
            type = "pie",
            marker = list(
                colors = colorRampPalette(c(
                    "#2C3E50",
                    "#B33A3A",
                    "#D98E04"
                ))(nrow(
                    by_cat
                ))
            ),
            textinfo = "label+percent"
        ) |>
            layout(showlegend = FALSE)
    })

    output$category_chart_income <- renderPlotly({
        by_cat <- financial_activity() |>
            filter(entry_type == "transaction", flow == "income") |>
            group_by(category_name) |>
            summarise(
                total = sum(signed_amount, na.rm = TRUE),
                .groups = "drop"
            ) |>
            filter(total != 0) |>
            arrange(desc(total))

        plot_ly(
            by_cat,
            labels = ~category_name,
            values = ~total,
            type = "pie",
            marker = list(
                colors = colorRampPalette(c(
                    "#2C3E50",
                    "#B33A3A",
                    "#D98E04"
                ))(nrow(
                    by_cat
                ))
            ),
            textinfo = "label+percent"
        ) |>
            layout(showlegend = FALSE)
    })

    output$dl_overview <- downloadHandler(
        filename = function() {
            paste0("overview_transactions_", Sys.Date(), ".csv")
        },
        content = function(file) {
            write.csv(
                financial_activity() |> filter(entry_type == "transaction"),
                file,
                row.names = FALSE,
                na = ""
            )
        }
    )

    ## ==================== GENERAL LEDGER ====================

    output$ledger_table <- renderDT({
        ledger_in_range() |>
            select(
                entry_date,
                entry_type,
                account_name,
                category_name,
                fund_name,
                member_name,
                signed_amount,
                description,
                entered_by_name,
                is_reversal, # new: TRUE if this row cancels a previous transaction
                voids_entry_date, # date of the original voided entry (if reversal)
                voided_reason # reason for voiding (if reversal)
            ) |>
            arrange(desc(entry_date)) |>
            datatable(
                filter = "top",
                options = list(pageLength = 20),
                rownames = FALSE
            ) |>
            formatCurrency("signed_amount", currency = "KES ")
    })

    output$dl_ledger <- downloadHandler(
        filename = function() paste0("ledger_", Sys.Date(), ".csv"),
        content = function(file) {
            write.csv(ledger_in_range(), file, row.names = FALSE, na = "")
        }
    )

    # Contribution history per member — right-joined onto the full member
    # list so members who haven't given anything (yet) still show up with
    # a zero, rather than silently disappearing from the table.
    member_contributions <- reactive({
        contributions <- financial_activity() |>
            filter(
                entry_type == "transaction",
                category_type == "income",
                !is.na(member_name)
            ) |>
            group_by(full_name = member_name) |>
            summarise(
                total_contributed = sum(signed_amount, na.rm = TRUE),
                last_contribution = if (any(signed_amount > 0)) {
                    max(entry_date[signed_amount > 0])
                } else {
                    as.Date(NA)
                },
                .groups = "drop"
            )

        raw()$members |>
            left_join(contributions, by = "full_name") |>
            mutate(total_contributed = coalesce(total_contributed, 0))
    })

    output$period_contributions <- renderValueBox({
        v <- financial_activity() |>
            filter(
                entry_type == "transaction",
                category_type == "income", # was !is_voided
                !is.na(member_name)
            ) |>
            pull(signed_amount) |>
            sum(na.rm = TRUE)
        valueBox(
            dollar(v, prefix = "KES "),
            "Member Contributions (period)",
            icon = icon("hand-holding-dollar"),
            color = "orange"
        )
    })

    output$contributing_members <- renderValueBox({
        v <- financial_activity() |>
            filter(
                entry_type == "transaction",
                category_type == "income",
                !is.na(member_name)
            ) |>
            group_by(member_name) |>
            summarise(
                net_contribution = sum(signed_amount, na.rm = TRUE),
                .groups = "drop"
            ) |>
            filter(net_contribution > 0) |>
            nrow()
        valueBox(
            v,
            "Members Who Gave (period)",
            icon = icon("hand-holding-heart"),
            color = "blue"
        )
    })

    output$avg_contribution <- renderValueBox({
        df <- financial_activity() |>
            filter(
                entry_type == "transaction",
                category_type == "income",
                !is.na(member_name)
            ) |>
            group_by(member_name) |>
            summarise(
                net_contribution = sum(signed_amount, na.rm = TRUE),
                .groups = "drop"
            ) |>
            filter(net_contribution > 0)

        v <- if (nrow(df) > 0) mean(df$net_contribution) else 0
        valueBox(
            dollar(v, prefix = "KES "),
            "Avg Net Gift (period)",
            icon = icon("chart-simple"),
            color = "green"
        )
    })

    output$contribution_status_chart <- renderPlotly({
        by_status <- member_contributions() |>
            filter(is_active) |>
            group_by(member_status) |>
            summarise(total = sum(total_contributed), .groups = "drop")

        p <- ggplot2::ggplot(
            by_status,
            ggplot2::aes(x = member_status, y = total, fill = member_status)
        ) +
            ggplot2::geom_col(width = 0.6) +
            ggplot2::scale_fill_manual(values = STATUS_COLORS) +
            ggplot2::scale_y_continuous(labels = function(x) {
                dollar(x, prefix = "KES ")
            }) +
            ggplot2::labs(x = NULL, y = NULL) +
            ggplot2::theme_minimal(base_size = 12) +
            ggplot2::theme(legend.position = "none")

        ggplotly(p)
    })

    output$members_contributions_table <- renderDT({
        member_contributions() |>
            select(
                full_name,
                phone_number,
                member_status,
                gender,
                total_contributed,
                last_contribution
            ) |>
            arrange(desc(total_contributed)) |>
            datatable(
                filter = "top",
                options = list(pageLength = 15),
                rownames = FALSE
            ) |>
            formatCurrency("total_contributed", currency = "KES ")
    })

    output$dl_contributions <- downloadHandler(
        filename = function() {
            paste0("member_contributions_", Sys.Date(), ".csv")
        },
        content = function(file) {
            write.csv(member_contributions(), file, row.names = FALSE, na = "")
        }
    )

    ## ==================== FUNDS ====================
    # Fund balance is cumulative (all transactions ever, not voided),
    # same logic as account_balances — "current standing", not a
    # date-filtered figure. The period chart/table below it does use
    # the date range, for "how has this fund moved lately".

    fund_balances <- reactive({
        raw()$ledger |>
            filter(
                entry_type == "transaction",
                !is.na(fund_name)
            ) |>
            group_by(fund = fund_name) |>
            summarise(
                balance = sum(signed_amount, na.rm = TRUE),
                .groups = "drop"
            ) |>
            right_join(raw()$funds_meta, by = "fund") |>
            mutate(balance = coalesce(balance, 0))
    })

    output$fund_boxes <- renderUI({
        fb <- fund_balances() |> filter(is_active)
        boxes <- lapply(seq_len(nrow(fb)), function(i) {
            row <- fb[i, ]
            valueBox(
                dollar(row$balance, prefix = "KES "),
                subtitle = paste0(
                    row$fund,
                    if (row$is_restricted) " (restricted)" else ""
                ),
                icon = icon(if (row$is_restricted) "lock" else "wallet"),
                color = if (row$is_restricted) "orange" else "blue",
                width = 3
            )
        })
        do.call(fluidRow, boxes)
    })

    output$fund_chart <- renderPlotly({
        fd <- financial_activity() |>
            filter(entry_type == "transaction", !is.na(fund_name)) |>
            mutate(
                amount = case_when(
                    flow == "income" ~ signed_amount,
                    flow == "expense" ~ -signed_amount,
                    TRUE ~ 0
                )
            ) |>
            group_by(fund_name, flow) |>
            summarise(total = sum(amount, na.rm = TRUE), .groups = "drop")

        p <- ggplot2::ggplot(
            fd,
            ggplot2::aes(x = fund_name, y = total, fill = flow)
        ) +
            ggplot2::geom_col(position = "dodge") +
            ggplot2::scale_fill_manual(
                values = c(income = "#2E8B57", expense = "#B33A3A")
            ) +
            ggplot2::scale_y_continuous(labels = function(x) {
                dollar(x, prefix = "KES ")
            }) +
            ggplot2::labs(x = NULL, y = NULL, fill = NULL) +
            ggplot2::theme_minimal(base_size = 12) +
            ggplot2::theme(
                axis.text.x = ggplot2::element_text(angle = 30, hjust = 1)
            )

        ggplotly(p)
    })

    output$fund_summary_table <- renderDT({
        fund_balances() |>
            select(fund, is_restricted, is_active, balance, description) |>
            arrange(desc(balance)) |>
            datatable(
                options = list(pageLength = 10, dom = "tp"),
                rownames = FALSE
            ) |>
            formatCurrency("balance", currency = "KES ")
    })

    output$dl_funds <- downloadHandler(
        filename = function() paste0("fund_summary_", Sys.Date(), ".csv"),
        content = function(file) {
            write.csv(fund_balances(), file, row.names = FALSE, na = "")
        }
    )

    ## ==================== MEMBERS ====================
    # Demographics only — no money here. See General Ledger > Member
    # Contributions for giving history.
    # Added map using location_text.

    output$total_members <- renderValueBox({
        valueBox(
            nrow(raw()$members),
            "Total Members",
            icon = icon("users"),
            color = "blue"
        )
    })

    output$active_members <- renderValueBox({
        v <- sum(raw()$members$is_active)
        valueBox(
            v,
            "Active Members",
            icon = icon("user-check"),
            color = "green"
        )
    })

    output$baptized_members <- renderValueBox({
        v <- sum(raw()$members$baptism_status)
        valueBox(v, "Baptized", icon = icon("water"), color = "orange")
    })

    output$confirmed_members <- renderValueBox({
        v <- sum(raw()$members$confirmation_status)
        valueBox(v, "Confirmed", icon = icon("cross"), color = "purple")
    })

    output$member_status_pie <- renderPlotly({
        by_status <- raw()$members |>
            filter(is_active) |>
            count(member_status)

        plot_ly(
            by_status,
            labels = ~member_status,
            values = ~n,
            type = "pie",
            marker = list(colors = STATUS_COLORS[by_status$member_status]),
            textinfo = "label+percent"
        ) |>
            layout(showlegend = FALSE)
    })

    output$member_gender_pie <- renderPlotly({
        by_gender <- raw()$members |>
            filter(is_active) |>
            count(gender)

        plot_ly(
            by_gender,
            labels = ~gender,
            values = ~n,
            type = "pie",
            marker = list(colors = GENDER_COLORS[by_gender$gender]),
            textinfo = "label+percent"
        ) |>
            layout(showlegend = FALSE)
    })

    output$members_table <- renderDT({
        raw()$members |>
            select(
                full_name,
                phone_number,
                gender,
                general_area,
                fellowship_group,
                member_status,
                baptism_status,
                confirmation_status,
                is_active
            ) |>
            arrange(full_name) |>
            datatable(
                filter = "top",
                options = list(pageLength = 15),
                rownames = FALSE
            )
    })

    output$dl_members <- downloadHandler(
        filename = function() paste0("members_", Sys.Date(), ".csv"),
        content = function(file) {
            df <- raw()$members |>
                select(
                    full_name,
                    phone_number,
                    gender,
                    general_area,
                    fellowship_group,
                    member_status,
                    baptism_status,
                    confirmation_status,
                    is_active
                ) |>
                arrange(full_name)
            write.csv(df, file, row.names = FALSE, na = "")
        }
    )

    output$dl_member_coords <- downloadHandler(
        filename = function() paste0("member_coordinates_", Sys.Date(), ".csv"),
        content = function(file) {
            df <- members_with_coords() |>
                filter(!is.na(lat), !is.na(lng)) |>
                select(
                    full_name,
                    member_status,
                    gender,
                    general_area,
                    fellowship_group,
                    lat,
                    lng
                )
            write.csv(df, file, row.names = FALSE, na = "")
        }
    )

    # ---- NEW: Member Map ----
    output$member_map <- renderLeaflet({
        m <- members_with_coords() |>
            filter(!is.na(lat), !is.na(lng))

        # use same colour palette as member status pie
        status_colors <- setNames(
            c("#3B6E9E", "#2E8B57", "#D98E04"),
            c("Student", "Working", "Retired")
        )
        pal <- colorFactor(
            status_colors,
            domain = names(status_colors)
        )

        map <- leaflet()

        if (nchar(CARTO_KEY) > 0) {
            map <- map |>
                addTiles(
                    urlTemplate = paste0(
                        "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=",
                        CARTO_KEY
                    ),
                    attribution = paste(
                        "&copy;",
                        '<a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>,',
                        '&copy; <a href="https://carto.com/attributions">CARTO</a>'
                    ),
                    options = tileOptions(subdomains = "abcd", maxZoom = 20)
                )
        } else {
            map <- map |> addProviderTiles("Esri.WorldGrayCanvas")
        }

        map <- map |>
            addLegend(
                "bottomright",
                pal = pal,
                values = names(status_colors),
                title = "Status"
            ) |>
            # Adds a printer-icon control directly on the map — click it to
            # export the current view as a PNG, entirely in-browser (no
            # server-side rendering, so no extra system dependencies).
            addEasyprint(
                options = easyprintOptions(
                    exportOnly = TRUE,
                    filename = paste0("members_map_", Sys.Date()),
                    hideControlContainer = FALSE,
                    sizeModes = list("CurrentSize")
                )
            )

        if (nrow(m) == 0) {
            return(
                map |> setView(lng = 39.850317, lat = -3.627606, zoom = 15)
            )
        }

        map |>
            addCircleMarkers(
                data = m,
                lng = ~lng,
                lat = ~lat,
                radius = 6,
                color = ~ pal(member_status),
                stroke = FALSE,
                fillOpacity = 0.85,
                popup = ~ paste0(
                    "<b>",
                    full_name,
                    "</b><br>",
                    general_area,
                    "<br>",
                    "Status: ",
                    member_status,
                    "<br>",
                    "Gender: ",
                    gender
                )
            )
    })

    ## ==================== VISITORS ====================
    # This is the tab meant to actually earn its keep for outreach:
    # who's coming, how they heard about us, and where they live.

    output$total_visitors <- renderValueBox({
        valueBox(
            nrow(raw()$visitors),
            "Total Visitors",
            icon = icon("person-walking-arrow-right"),
            color = "blue"
        )
    })

    output$active_visitors <- renderValueBox({
        v <- sum(raw()$visitors$visitor_status == "active")
        valueBox(
            v,
            "Active (Not Yet Converted)",
            icon = icon("hourglass-half"),
            color = "orange"
        )
    })

    output$conversion_rate <- renderValueBox({
        v <- raw()$visitors
        rate <- if (nrow(v) > 0) mean(v$visitor_status == "converted") else 0
        valueBox(
            percent(rate, accuracy = 1),
            "Converted to Membership",
            icon = icon("arrow-right-to-bracket"),
            color = "purple"
        )
    })

    output$visitors_trend_chart <- renderPlotly({
        monthly <- raw()$visitors |>
            mutate(month = floor_date(first_visit_date, "month")) |>
            count(month, name = "new_visitors")

        p <- ggplot2::ggplot(
            monthly,
            ggplot2::aes(x = month, y = new_visitors)
        ) +
            ggplot2::geom_col(fill = "#3B6E9E") +
            ggplot2::geom_smooth(
                se = FALSE,
                color = "#D98E04",
                linewidth = 0.9,
                method = "loess",
                formula = y ~ x
            ) +
            ggplot2::labs(x = NULL, y = "New visitors") +
            ggplot2::theme_minimal(base_size = 12)

        ggplotly(p)
    })

    output$visitor_status_pie <- renderPlotly({
        by_status <- raw()$visitors |> count(visitor_status)

        plot_ly(
            by_status,
            labels = ~visitor_status,
            values = ~n,
            type = "pie",
            hole = 0.45,
            marker = list(
                colors = VISITOR_STATUS_COLORS[by_status$visitor_status]
            ),
            textinfo = "label+percent"
        ) |>
            layout(showlegend = FALSE)
    })

    output$how_heard_chart <- renderPlotly({
        by_heard <- raw()$visitors |>
            count(how_heard) |>
            arrange(n)

        p <- ggplot2::ggplot(
            by_heard,
            ggplot2::aes(x = reorder(how_heard, n), y = n)
        ) +
            ggplot2::geom_col(fill = "#6B4C9A", width = 0.6) +
            ggplot2::coord_flip() +
            ggplot2::labs(x = NULL, y = "Visitors") +
            ggplot2::theme_minimal(base_size = 12)

        ggplotly(p)
    })

    output$visitor_gender_pie <- renderPlotly({
        by_gender <- raw()$visitors |> count(gender)

        plot_ly(
            by_gender,
            labels = ~gender,
            values = ~n,
            type = "pie",
            marker = list(colors = GENDER_COLORS[by_gender$gender]),
            textinfo = "label+percent"
        ) |>
            layout(showlegend = FALSE)
    })

    output$visitor_map <- renderLeaflet({
        v <- visitors_with_coords() |>
            filter(!is.na(lat), !is.na(lng))

        pal <- colorFactor(
            VISITOR_STATUS_COLORS,
            domain = names(
                VISITOR_STATUS_COLORS
            )
        )

        map <- leaflet()

        if (nchar(CARTO_KEY) > 0) {
            map <- map |>
                addTiles(
                    urlTemplate = paste0(
                        "https://{s}.basemaps.cartocdn.com/light_all/{z}/{x}/{y}{r}.png?key=",
                        CARTO_KEY
                    ),
                    attribution = paste(
                        "&copy;",
                        '<a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>,',
                        '&copy; <a href="https://carto.com/attributions">CARTO</a>'
                    ),
                    options = tileOptions(subdomains = "abcd", maxZoom = 20)
                )
        } else {
            map <- map |> addProviderTiles("Esri.WorldGrayCanvas")
        }

        map <- map |>
            addLegend(
                "bottomright",
                pal = pal,
                values = names(VISITOR_STATUS_COLORS),
                title = "Status"
            ) |>
            addEasyprint(
                options = easyprintOptions(
                    exportOnly = TRUE,
                    filename = paste0("visitors_map_", Sys.Date()),
                    hideControlContainer = FALSE,
                    sizeModes = list("CurrentSize")
                )
            )

        if (nrow(v) == 0) {
            return(
                map |> setView(lng = 39.850317, lat = -3.627606, zoom = 15)
            )
        }

        map |>
            addCircleMarkers(
                data = v,
                lng = ~lng,
                lat = ~lat,
                radius = 6,
                color = ~ pal(visitor_status),
                stroke = FALSE,
                fillOpacity = 0.85,
                popup = ~ paste0(
                    "<b>",
                    full_name,
                    "</b><br>",
                    general_area,
                    "<br>Status: ",
                    visitor_status,
                    "<br>Heard via: ",
                    how_heard
                )
            )
    })

    output$dl_visitors <- downloadHandler(
        filename = function() paste0("visitors_", Sys.Date(), ".csv"),
        content = function(file) {
            df <- raw()$visitors |>
                select(
                    full_name,
                    phone_number,
                    gender,
                    general_area,
                    how_heard,
                    first_visit_date,
                    visitor_status,
                    invited_by
                ) |>
                arrange(desc(first_visit_date))
            write.csv(df, file, row.names = FALSE, na = "")
        }
    )

    output$dl_visitor_coords <- downloadHandler(
        filename = function() {
            paste0("visitor_coordinates_", Sys.Date(), ".csv")
        },
        content = function(file) {
            df <- visitors_with_coords() |>
                filter(!is.na(lat), !is.na(lng)) |>
                select(
                    full_name,
                    visitor_status,
                    gender,
                    general_area,
                    how_heard,
                    lat,
                    lng
                )
            write.csv(df, file, row.names = FALSE, na = "")
        }
    )

    output$visitors_table <- renderDT({
        raw()$visitors |>
            select(
                full_name,
                phone_number,
                gender,
                general_area,
                how_heard,
                first_visit_date,
                visitor_status,
                invited_by
            ) |>
            arrange(desc(first_visit_date)) |>
            datatable(
                filter = "top",
                options = list(pageLength = 15),
                rownames = FALSE
            )
    })
}

shinyApp(ui, server)

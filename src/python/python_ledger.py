# Import Libraries
import argparse
import json
import os
import sys
from datetime import datetime

import numpy as np
import pandas as pd
from sqlalchemy import create_engine, text


# Function to validate the date input
def parse_date(date_str):
    """Validate that the input string matches YYYY-MM-DD format."""
    try:
        return datetime.strptime(date_str, "%Y-%m-%d").strftime("%Y-%m-%d")
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid date format: '{date_str}'. Expected 'YYYY-MM-DD'."
        )

# --- Comparative Offertory bars ---
def save_comparative_offertory_bars(df, start_date, end_date):
    # 1. Determine how many months are in the period
    num_months = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1

    # 2. Calculate the start of the previous period
    prev_start = start_date - pd.DateOffset(months=num_months)
    prev_end = start_date - pd.Timedelta(days=1)
    
    # Function to get data subset for start and end dates
    def get_monthly_data(s, e, by_quarter=False):
        subset = df[(df['date'] >= s) & (df['date'] <= e) & (df['category'].str.contains('Offertory', na=False))\
                    & (df['transaction_type'] == 'Income')]
        
        # 2. Safety Check:
        if subset.empty:
            return pd.Series(dtype='float64')

        if by_quarter:
            # 3. Vectorized approach: Faster and avoids the "Multiple Columns" error
            quarter_map = {1: 'Jan-Mar', 2: 'Apr-Jun', 3: 'Jul-Sep', 4: 'Oct-Dec'}
            
            # We create the label by combining two simple Series
            q_names = subset['date'].dt.quarter.map(quarter_map)
            years = subset['date'].dt.year.astype(str)
            
            subset['quarter_label'] = q_names + " " + years
            return subset.groupby('quarter_label', sort=False)['amount'].sum()
        else:
            # Standard monthly grouping
            return subset.groupby(subset['date'].dt.strftime('%b %Y'), sort=False)['amount'].sum()
    
    prev_vals = get_monthly_data(prev_start, prev_end, by_quarter=(num_months >= 6))
    curr_vals = get_monthly_data(start_date, end_date, by_quarter=(num_months >= 6))

    # 3. Calculate means for trend comparison
    prev_total = prev_vals.sum()
    curr_total = curr_vals.sum()
    prev_mean = prev_total / len(prev_vals) if len(prev_vals) > 0 else 0
    curr_mean = curr_total / len(curr_vals) if len(curr_vals) > 0 else 0

    if prev_mean == 0:
        summary_text = "Initial period of reporting."
    else:
        percent_change = ((curr_mean - prev_mean) / prev_mean) * 100

        if percent_change > 0:
            color = "green"
            direction = "improved"
        else:
            color = "red"
            direction = "decreased"
        
        summary_text = (
            rf"Offertory income has \textcolor{{{color}}}{{\textbf{{{direction}}} "
            rf"by \textbf{{{abs(percent_change):.1f}\%}}}} compared to the previous period."
        )

    # 4. Plotting for number of months > 6, we show quarterly bars, otherwise monthly
    all_labels = list(prev_vals.index) + list(curr_vals.index)
    all_values = list(prev_vals.values) + list(curr_vals.values)

    # Assigning colours
    colors = ['#1976D2'] * len(prev_vals) + ['#2E7D32'] * len(curr_vals)

    return summary_text

# --- Comparative Tithe bars ---
def save_comparative_tithe_bars(df, start_date, end_date):
    # 1. Determine how many months are in the period
    num_months = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1

    # 2. Calculate the start of the previous period
    prev_start = start_date - pd.DateOffset(months=num_months)
    prev_end = start_date - pd.Timedelta(days=1)
    
    # Function to get data subset for start and end dates
    def get_monthly_data(s, e, by_quarter=False):
        subset = df[(df['date'] >= s) & (df['date'] <= e) & (df['category'].str.contains('Tithe', na=False))\
                    & (df['transaction_type'] == 'Income')]
        
        # 2. Safety Check:
        if subset.empty:
            return pd.Series(dtype='float64')

        if by_quarter:
            # 3. Vectorized approach: Faster and avoids the "Multiple Columns" error
            quarter_map = {1: 'Jan-Mar', 2: 'Apr-Jun', 3: 'Jul-Sep', 4: 'Oct-Dec'}
            
            # We create the label by combining two simple Series
            q_names = subset['date'].dt.quarter.map(quarter_map)
            years = subset['date'].dt.year.astype(str)
            
            subset['quarter_label'] = q_names + " " + years
            return subset.groupby('quarter_label', sort=False)['amount'].sum()
        else:
            # Standard monthly grouping
            return subset.groupby(subset['date'].dt.strftime('%b %Y'), sort=False)['amount'].sum()
    
    prev_vals = get_monthly_data(prev_start, prev_end, by_quarter=(num_months >= 6))
    curr_vals = get_monthly_data(start_date, end_date, by_quarter=(num_months >= 6))

    # 3. Calculate means for trend comparison
    prev_total = prev_vals.sum()
    curr_total = curr_vals.sum()
    prev_mean = prev_total / len(prev_vals) if len(prev_vals) > 0 else 0
    curr_mean = curr_total / len(curr_vals) if len(curr_vals) > 0 else 0

    if prev_mean == 0:
        summary_text = "Initial period of reporting."
    else:
        percent_change = ((curr_mean - prev_mean) / prev_mean) * 100

        if percent_change > 0:
            color = "green"
            direction = "improved"
        else:
            color = "red"
            direction = "decreased"
        
        summary_text = (
            rf"Tithe income has \textcolor{{{color}}}{{\textbf{{{direction}}} "
            rf"by \textbf{{{abs(percent_change):.1f}\%}}}} compared to the previous period."
        )

    # 4. Plotting for number of months > 6, we show quarterly bars, otherwise monthly
    all_labels = list(prev_vals.index) + list(curr_vals.index)
    all_values = list(prev_vals.values) + list(curr_vals.values)

    # Assigning colours
    colors = ['#1976D2'] * len(prev_vals) + ['#2E7D32'] * len(curr_vals)

    return summary_text

# --- Comparative Shukrani bars ---
def save_comparative_shukrani_bars(df, start_date, end_date):
    # 1. Determine how many months are in the period
    num_months = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1

    # 2. Calculate the start of the previous period
    prev_start = start_date - pd.DateOffset(months=num_months)
    prev_end = start_date - pd.Timedelta(days=1)
    
    # Function to get data subset for start and end dates
    def get_monthly_data(s, e, by_quarter=False):
        subset = df[(df['date'] >= s) & (df['date'] <= e) & (df['category'].str.contains('Shukrani', na=False))\
                    & (df['transaction_type'] == 'Income')]
        
        # 2. Safety Check:
        if subset.empty:
            return pd.Series(dtype='float64')

        if by_quarter:
            # 3. Vectorized approach: Faster and avoids the "Multiple Columns" error
            quarter_map = {1: 'Jan-Mar', 2: 'Apr-Jun', 3: 'Jul-Sep', 4: 'Oct-Dec'}
            
            # We create the label by combining two simple Series
            q_names = subset['date'].dt.quarter.map(quarter_map)
            years = subset['date'].dt.year.astype(str)
            
            subset['quarter_label'] = q_names + " " + years
            return subset.groupby('quarter_label', sort=False)['amount'].sum()
        else:
            # Standard monthly grouping
            return subset.groupby(subset['date'].dt.strftime('%b %Y'), sort=False)['amount'].sum()
    
    prev_vals = get_monthly_data(prev_start, prev_end, by_quarter=(num_months >= 6))
    curr_vals = get_monthly_data(start_date, end_date, by_quarter=(num_months >= 6))

    # 3. Calculate means for trend comparison
    prev_total = prev_vals.sum()
    curr_total = curr_vals.sum()
    prev_mean = prev_total / len(prev_vals) if len(prev_vals) > 0 else 0
    curr_mean = curr_total / len(curr_vals) if len(curr_vals) > 0 else 0

    if prev_mean == 0:
        summary_text = "Initial period of reporting."
    else:
        percent_change = ((curr_mean - prev_mean) / prev_mean) * 100

        if percent_change > 0:
            color = "green"
            direction = "improved"
        else:
            color = "red"
            direction = "decreased"
        
        summary_text = (
            rf"Shukrani income has \textcolor{{{color}}}{{\textbf{{{direction}}} "
            rf"by \textbf{{{abs(percent_change):.1f}\%}}}} compared to the previous period."
        )

    # 4. Plotting for number of months > 6, we show quarterly bars, otherwise monthly
    all_labels = list(prev_vals.index) + list(curr_vals.index)
    all_values = list(prev_vals.values) + list(curr_vals.values)

    # Assigning colours
    colors = ['#1976D2'] * len(prev_vals) + ['#2E7D32'] * len(curr_vals)

    return summary_text

# --- Assessment expenditure performance ---
def save_assessment_expenditure_bars(df, start_date, end_date, targets_df):
    # 1. Determine period length and grouping logic
    num_months = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1
    by_quarter = num_months >= 6

    # 2. Extract Assessment Expense Targets
    expense_targets = targets_df[targets_df['category'] == 'Assessment']
    target_lookup = dict(zip(expense_targets['year'], expense_targets['monthly_target']))
    
    # 3. Generate the full time range
    date_range = pd.date_range(start_date, end_date, freq='MS')
    temp_df = pd.DataFrame({'date': date_range})

    if by_quarter:
        quarter_map = {1: 'Jan-Mar', 2: 'Apr-Jun', 3: 'Jul-Sep', 4: 'Oct-Dec'}
        temp_df['label'] = temp_df['date'].dt.quarter.map(quarter_map) + " " + temp_df['date'].dt.year.astype(str)
        time_labels = temp_df['label'].unique().tolist()
    else:
        time_labels = temp_df['date'].dt.strftime('%b %Y').tolist()

    # 4. Get Actuals and Align with Full Range
    actual_data = df[(df['date'] >= start_date) & (df['date'] <= end_date) & 
                     (df['category'] == 'Assessment Paid') & (df['transaction_type'] == 'Expense')].copy()

    if not actual_data.empty:
        if by_quarter:
            quarter_map = {1: 'Jan-Mar', 2: 'Apr-Jun', 3: 'Jul-Sep', 4: 'Oct-Dec'}
            actual_data['label'] = actual_data['date'].dt.quarter.map(quarter_map) + " " + actual_data['date'].dt.year.astype(str)
        else:
            actual_data['label'] = actual_data['date'].dt.strftime('%b %Y')
        
        actual_grouped = actual_data.groupby('label')['amount'].sum()
    else:
        actual_grouped = pd.Series(dtype=float)

    # Reindex actuals to the full time_labels (fills gaps with 0)
    actual_values = [actual_grouped.get(label, 0) for label in time_labels]

    # 5. Calculate Targets for EVERY period in the range
    current_targets = []
    for label in time_labels:
        year = int(label.split()[-1])
        m_target = target_lookup.get(year, 0)
        current_targets.append(m_target * 3 if by_quarter else m_target)

    # 6. Performance Calculation
    total_actual = sum(actual_values)
    total_target = sum(current_targets)
    perf_pct = (total_actual / total_target) * 100 if total_target > 0 else 0

    # 8. Stewardship Signal
    t_color = "Gold" if perf_pct >= 100 else "green" if perf_pct > 80 else "red"
    assessment_msg = (
        rf"In this period, the assessment expenditure performance has been at "
        rf"\textcolor{{{t_color}}}{{\textbf{{{perf_pct:.1f}\%}}}} of the Synod target."
    )

    return assessment_msg

# Create the hand-off function
def generate_church_report(
    df,
    start_str,
    end_str,
    targets_df,
    db_engine
) -> None:
    start_date = pd.to_datetime(start_str)
    end_date = pd.to_datetime(end_str) + pd.offsets.MonthEnd(0)
    
    period_label = f"{start_date.strftime('%d %b %Y')} -- {end_date.strftime('%d %b %Y')}"
    file_base_name = f"report_{start_date.strftime('%b%y')}_{end_date.strftime('%b%y')}".lower()
    
    # --- 2. NEW Opening Balances Logic ---
    # Fetch base opening balances from the database schema
    acc_df = pd.read_sql("SELECT name, opening_balance FROM accounts", db_engine)
    base_bank = acc_df[acc_df['name'].str.contains('bank', case=False)]['opening_balance'].sum()
    base_cash = acc_df[acc_df['name'].str.contains('cash|m-pesa', case=False)]['opening_balance'].sum()

    # Calculate movement strictly BEFORE the start_date
    prior_data = df[df['date'] < start_date]
    prior_bank_move = prior_data[prior_data['account'].str.contains('bank', case=False)]['correct_amount'].sum()
    prior_cash_move = prior_data[prior_data['account'].str.contains('cash|m-pesa', case=False)]['correct_amount'].sum()
    
    opening_bank = base_bank + prior_bank_move
    opening_cash = base_cash + prior_cash_move
    total_opening = opening_bank + opening_cash
    
    # --- 3. Filtering for Current Period ---
    # We no longer need to worry about excluding "Opening" types, because they don't exist in the ledger anymore!
    current_period_mask = (df['date'] >= start_date) & (df['date'] <= end_date)
    report_data = df.loc[current_period_mask].copy()
    
    # 4. STRATIFIED CLOSING BALANCES (Balance C/F)
    # Calculate how each account changed specifically in this window
    bank_change = report_data[report_data['account'] == 'Bank']['correct_amount'].sum()
    cash_change = report_data[report_data['account'].str.contains('cash|m-pesa', case=False)]['correct_amount'].sum()
    
    closing_bank = opening_bank + bank_change
    closing_cash = opening_cash + cash_change
    
    # 5. Build the T-Account Lists
    # Grouping categories for the table
    summary = report_data.groupby(['transaction_type', 'category'])['amount'].sum().reset_index()
    income_summary = summary[summary['transaction_type'] == 'Income']
    expense_summary = summary[summary['transaction_type'] == 'Expense']
    expense_summary = expense_summary.sort_values(by='amount', ascending=False)

    inc_list = [
        ("Balance B/F (Bank)", opening_bank),
        ("Balance B/F (Cash)", opening_cash)
    ]
    
    # NEW: Iteratively build the income list to inject the Assessment breakdown
    for _, row in income_summary.iterrows():
        cat = row['category']
        amt = row['amount']
        
        # 1. Add the main Income line (e.g., "Assessment", "Offertory")
        inc_list.append((cat, amt))
        
        # 2. If the category is Assessment, fetch and append the breakdown
        if cat == 'Assessment Received':
            # Filter the raw report_data for just the Assessment incomes
            assessment_breakdown = report_data[(report_data['transaction_type'] == 'Income') & 
                                               (report_data['category'] == 'Assessment Received')]
            
            # Group by 'description' (which contains the church names) and sort highest to lowest
            church_totals = assessment_breakdown.groupby('description')['amount'].sum().sort_values(ascending=False)
            
            for church, b_amt in church_totals.items():
                # Use LaTeX formatting to indent (\hspace) and italicize (\textit) the church name
                # This makes it visually distinct from the main categories
                formatted_church_name = rf"\hspace{{4mm}} \textit{{{church}}}"
                inc_list.append((formatted_church_name, b_amt))
    
    # Add the expenses to their list
    exp_list = expense_summary[['category', 'amount']].values.tolist()

    # NEW: Calculate and append the Expenditure Subtotal
    total_expenditure = expense_summary['amount'].sum()
    
    # We use \textbf{} so it stands out visually from regular expense categories
    exp_list.append((r"\textbf{Subtotal}", total_expenditure))
    
    # 6. Formatting for LaTeX Table Rows
    max_l = max(len(inc_list), len(exp_list))
    rows_string = ""
    for i in range(max_l):
        i_cat = inc_list[i][0] if i < len(inc_list) else ""
        i_val = f"{inc_list[i][1]:,.2f}" if i < len(inc_list) else ""
        e_cat = exp_list[i][0] if i < len(exp_list) else ""
        e_val = f"{exp_list[i][1]:,.2f}" if i < len(exp_list) else ""
        
        # Only print the row if there is at least one category present
        rows_string += f"{i_cat} & {i_val} & {e_cat} & {e_val} \\\\ \n"

    # 7. Grand Totals (Receipts must equal Payments + Closing Balances)
    total_receipts = total_opening + income_summary['amount'].sum()
    
    # 8. HAND OFF (Run the math functions - returning ONLY text now)
    offertory_text = save_comparative_offertory_bars(df, start_date, end_date)
    tithe_text = save_comparative_tithe_bars(df, start_date, end_date)
    shukrani_text = save_comparative_shukrani_bars(df, start_date, end_date)
    assessment_expenditure_text = save_assessment_expenditure_bars(df, start_date, end_date, targets_df)

    # 9. EXPORTING TO SHARED VOLUME (/data)
    os.makedirs("/data/exports", exist_ok=True)
    os.makedirs("/data/table", exist_ok=True)

    # Export Data for R
    df.to_csv("/data/exports/ledger_export.csv", index=False)
    targets_df.to_csv("/data/exports/targets_export.csv", index=False)

    # Export Data for LaTeX
    data_to_pass = {
        'file_base_name': file_base_name,
        'period_label': period_label,
        'table_rows': rows_string, # Calculated in step 6
        'closing_bank': f"{closing_bank:,.2f}",
        'closing_cash': f"{closing_cash:,.2f}",
        'total_sum': f"{total_receipts:,.2f}", # Calculated in step 7
        'offertory_summary_text': offertory_text,
        'tithe_summary_text': tithe_text,
        'shukrani_summary_text': shukrani_text,
        'assessment_expenditure_text': assessment_expenditure_text,
        'report_gen_date': datetime.now().strftime('%d/%m/%Y')
    }

    with open("/data/table/report_summary.json", "w") as f:
        json.dump(data_to_pass, f, indent=4)
    
    print(f"✅ Data successfully exported to /data/ for {period_label}")

# =====================
# The main block
# =====================
if __name__ == "__main__":
    try:
        # 1. Connect to Postgres
        POSTGRES_USER = os.getenv("POSTGRES_USER")
        POSTGRES_PASSWORD = os.getenv("POSTGRES_PASSWORD")
        POSTGRES_DB = os.getenv("POSTGRES_DB")

        engine = create_engine(
            f"postgresql://{POSTGRES_USER}:{POSTGRES_PASSWORD}@localhost:5432/{POSTGRES_DB}"
        )
        
        # 2. Query the General Ledger View and map it to your old DataFrame format
        ledger_query = """
            -- PART 1: Standard Incomes and Expenses
            SELECT 
                t.transaction_date AS date,
                CASE WHEN c.category_type = 'income' THEN 'Income' ELSE 'Expense' END AS transaction_type,
                c.name AS category,
                COALESCE(mem.full_name, NULLIF(t.description, '')) AS description,
                a.name AS account,
                t.amount AS amount,
                CASE WHEN c.category_type = 'income' THEN t.amount ELSE -t.amount END AS correct_amount
            FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            JOIN categories c ON c.id = t.category_id
            LEFT JOIN members mem ON mem.id = t.member_id
            WHERE NOT t.is_voided

            UNION ALL

            -- PART 2: Transfer OUT (Negative impact on sender account)
            SELECT 
                tr.transfer_date AS date,
                'Transfer' AS transaction_type,
                'Transfer' AS category,
                NULLIF(tr.description, '') AS description,
                a_from.name AS account,
                tr.amount AS amount,
                -tr.amount AS correct_amount
            FROM transfers tr
            JOIN accounts a_from ON a_from.id = tr.from_account_id
            WHERE NOT tr.is_voided

            UNION ALL

            -- PART 3: Transfer IN (Positive impact on receiver account)
            SELECT 
                tr.transfer_date AS date,
                'Transfer' AS transaction_type,
                'Transfer' AS category,
                NULLIF(tr.description, '') AS description,
                a_to.name AS account,
                tr.amount AS amount,
                tr.amount AS correct_amount
            FROM transfers tr
            JOIN accounts a_to ON a_to.id = tr.to_account_id
            WHERE NOT tr.is_voided
        """

        ledger_df = pd.read_sql(ledger_query, engine)
        ledger_df['date'] = pd.to_datetime(ledger_df['date'])
        ledger_df['account'] = ledger_df['account'].str.title()

        # 3. Query Targets (Joining both target tables to match your old format)
        targets_query = """
            SELECT 
                COALESCE(m.full_name, st.member_status, 'Fellowship') AS "Entity",
                st.year,
                CASE 
                    WHEN st.period = 'Annual' THEN st.target_amount / 12.0 
                    ELSE st.target_amount 
                END AS monthly_target,
                c.name AS category
            FROM society_targets st
            JOIN categories c ON c.id = st.target_category_id
            LEFT JOIN members m ON m.id = st.member_id
        """
        targets_df = pd.read_sql(targets_query, engine)

        # Rename category in the targets dataframe to match
        targets_df['category'] = targets_df['category'].replace('Assessment Paid', 'Synod Assessment')

        # 4. Handle Arguments
        today = datetime.today()
        default_start = today.strftime('%Y-%m-01')

        parser = argparse.ArgumentParser(
            description="Extract ledger data and generate financial report metrics for a specified period."
        )
        parser.add_argument(
            "--start_date", "-start",
            nargs="?",
            type=parse_date,
            default=default_start,
            help="Start date in YYYY-MM-DD format (default: %(default)s)"
        )
        parser.add_argument(
            "--end_date", "-end",
            nargs="?",
            type=parse_date,
            default=None,
            help="End date in YYYY-MM-DD format (default: matches start_date)"
        )

        args = parser.parse_args()
        
        start_date = args.start_date
        end_date = args.end_date if args.end_date is not None else start_date
        
        # Pass the engine to the main function so it can query opening balances
        generate_church_report(ledger_df, start_date, end_date, targets_df, engine)

    except Exception as e:
        print(f"An unexpected error occurred: {e}")
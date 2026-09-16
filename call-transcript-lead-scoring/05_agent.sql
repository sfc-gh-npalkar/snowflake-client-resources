/* ============================================================================
   Snowflake Cortex Workshop
   05_agent.sql -- The agent, and how it chooses between tools

   Creates REFI_INTELLIGENCE_AGENT with two tools:

     Query_Refinance_Data         Cortex Analyst over the semantic view.
                                  Answers questions about populations: counts,
                                  totals, rankings, breakdowns, lists.

     Refinance_Propensity_Score   The GET_REFI_PROPENSITY procedure from
                                  04_scoring.sql. Answers questions about one
                                  named borrower.

   The agent is created in SNOWFLAKE_INTELLIGENCE.AGENTS so that it appears in
   the agent picker in Snowflake CoWork. An agent created only in an
   application schema works over SQL and REST but does not show up in the UI.

   Most of the effort in this file is in the orchestration instructions. Two
   tools that both plausibly answer "tell me about this borrower" will be
   confused with each other unless the boundary is stated explicitly, so the
   instructions name the question shapes that belong to each tool and give the
   agent a rule for the ambiguous case.

   Safe to re-run.
   ========================================================================== */

USE WAREHOUSE CORTEX_DEMO_WH;
USE DATABASE CORTEX_REFI_DEMO;
USE SCHEMA MORTGAGE;


-- ---------------------------------------------------------------------------
-- Grants
--
-- The role that queries the agent needs USAGE on the procedure and
-- REFERENCES + SELECT on the semantic view. Adjust the role as needed.
-- ---------------------------------------------------------------------------
-- GRANT USAGE ON PROCEDURE GET_REFI_PROPENSITY(VARCHAR) TO ROLE <query_role>;
-- GRANT REFERENCES, SELECT ON SEMANTIC VIEW REFI_INTELLIGENCE TO ROLE <query_role>;


-- ---------------------------------------------------------------------------
-- The agent
-- ---------------------------------------------------------------------------
CREATE OR REPLACE AGENT SNOWFLAKE_INTELLIGENCE.AGENTS.REFI_INTELLIGENCE_AGENT
WITH PROFILE = '{"display_name": "Refinance Intelligence", "color": "blue"}'
COMMENT = 'Refinance lead intelligence agent. Queries the loan book and extracted call signals via a semantic view, and scores individual borrowers with a Snowpark propensity model. Synthetic data.'
FROM SPECIFICATION $$
models:
  orchestration: auto

instructions:
  response: |
    You help mortgage retention and origination teams find and qualify
    refinance opportunities. Be concise and lead with the number or the list
    the user asked for. Use dollar figures with thousands separators and quote
    rates to two decimal places.

    Never estimate a propensity score yourself. Scores come only from the
    Refinance_Propensity_Score tool.

    All data is synthetic and for demonstration purposes.

  orchestration: |
    You have two tools and they answer different kinds of question. Choose
    deliberately.

    Use Query_Refinance_Data for anything about a population, a count, a total,
    an average, a ranking, a breakdown, or a list of borrowers. Examples:
    which homeowners match a segment, how many called last week, total savings
    available, average rate by state, call volume by agent, breakdown by call
    intent.

    Use Refinance_Propensity_Score when the user asks how likely one specific,
    named borrower is to refinance, or asks for that borrower's score, or asks
    why their score is what it is. Pass the borrower name exactly as the user
    gave it. If the tool reports multiple matches, show the candidate list and
    ask which one rather than picking one.

    Do not use Refinance_Propensity_Score to score a list. If the user wants
    the highest-propensity borrowers across a group, first use
    Query_Refinance_Data to retrieve the relevant borrowers, then score
    individuals only if the user names them.

    When asked about the top refinance segment, use the refi_segment dimension
    rather than rebuilding the criteria from rate, LTV and credit filters. The
    segment is already defined in the semantic view.

  sample_questions:
    - question: "Which homeowners from last week's calls match our top refinance segment?"
    - question: "What is the propensity score for Farrah Haddad?"
    - question: "How many inbound calls did we get last week by call intent?"
    - question: "What is the total monthly savings available in the top refinance segment?"

tools:
  - tool_spec:
      type: cortex_analyst_text_to_sql
      name: Query_Refinance_Data
      description: |
        Queries the mortgage loan book joined to signals extracted from inbound
        call transcripts. Use for populations, counts, totals, averages,
        rankings, breakdowns and lists of borrowers. Contains loan terms,
        interest rate versus market, LTV, credit band, property valuation,
        estimated refinance savings, the top refinance segment flag, the
        modelled propensity score, and per-call intent, urgency, competitor
        mentions and summaries.

  - tool_spec:
      type: generic
      name: Refinance_Propensity_Score
      description: |
        Returns the modelled probability that one specific named borrower will
        refinance, along with the factors raising and lowering that score and
        the borrower's loan position. Use only for an individual named
        borrower, never for a group or a list.
      input_schema:
        type: object
        properties:
          borrower_name:
            type: string
            description: Full or partial name of the homeowner, for example 'Farrah Haddad'.
        required:
          - borrower_name

tool_resources:
  Query_Refinance_Data:
    semantic_view: CORTEX_REFI_DEMO.MORTGAGE.REFI_INTELLIGENCE
    execution_environment:
      type: warehouse
      warehouse: CORTEX_DEMO_WH
      query_timeout: 90
  Refinance_Propensity_Score:
    type: procedure
    identifier: CORTEX_REFI_DEMO.MORTGAGE.GET_REFI_PROPENSITY
    execution_environment:
      type: warehouse
      warehouse: CORTEX_DEMO_WH
      query_timeout: 90
$$;


-- ---------------------------------------------------------------------------
-- Confirm the agent exists and is visible
-- ---------------------------------------------------------------------------
SHOW AGENTS IN SCHEMA SNOWFLAKE_INTELLIGENCE.AGENTS;


-- ---------------------------------------------------------------------------
-- Calling the agent from SQL
--
-- Two things about DATA_AGENT_RUN that are easy to trip over:
--
--   The payload argument must be a constant string. PARSE_JSON() or a column
--   reference fails with "needs to be constant".
--
--   The response is a JSON object with a content array holding the whole turn:
--   the agent's thinking, each tool call, each tool result, and the final text.
--   Flatten it and filter to see just the answer, or inspect the tool_use
--   entries to confirm which tool actually fired.
-- ---------------------------------------------------------------------------

-- Population question. Expect Query_Refinance_Data.
WITH r AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'SNOWFLAKE_INTELLIGENCE.AGENTS.REFI_INTELLIGENCE_AGENT',
    '{"messages":[{"role":"user","content":[{"type":"text","text":"Which homeowners from last weeks calls match our top refinance segment? Give me the top 5 by monthly saving."}]}]}'
  )) AS j
)
SELECT f.value:type::STRING                                        AS content_type,
       COALESCE(f.value:text::STRING, f.value:tool_use:name::STRING) AS detail
FROM r, LATERAL FLATTEN(input => j:content) f;


-- Single borrower question. Expect Refinance_Propensity_Score.
WITH r AS (
  SELECT PARSE_JSON(SNOWFLAKE.CORTEX.DATA_AGENT_RUN(
    'SNOWFLAKE_INTELLIGENCE.AGENTS.REFI_INTELLIGENCE_AGENT',
    '{"messages":[{"role":"user","content":[{"type":"text","text":"What is the propensity score for Farrah Haddad, and why?"}]}]}'
  )) AS j
)
SELECT f.value:type::STRING                                        AS content_type,
       COALESCE(f.value:text::STRING, f.value:tool_use:name::STRING) AS detail
FROM r, LATERAL FLATTEN(input => j:content) f;


-- ---------------------------------------------------------------------------
-- Continue to 06_verified_query.sql.
-- ---------------------------------------------------------------------------

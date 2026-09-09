"""
Domain Risk Operations Center
Streamlit dashboard for monitoring and investigating suspicious domain registrations.
"""
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="Domain Risk Center", page_icon="🛡️", layout="wide")

session = get_active_session()

st.title("Domain Risk Operations Center")
st.caption("Automated detection of suspicious domain registrations")

# --- KPI Section ---
col1, col2, col3, col4 = st.columns(4)

stats = session.sql("""
    SELECT 
        COUNT(*) as total_domains,
        SUM(CASE WHEN risk_tier = 'HIGH' THEN 1 ELSE 0 END) as high_risk,
        SUM(CASE WHEN risk_tier = 'MEDIUM' THEN 1 ELSE 0 END) as medium_risk,
        SUM(CASE WHEN risk_tier = 'LOW' THEN 1 ELSE 0 END) as low_risk
    FROM DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.DOMAIN_RISK_SCORES
""").to_pandas().iloc[0]

col1.metric("Total Domains", f"{stats['TOTAL_DOMAINS']:,}")
col2.metric("High Risk (Block)", f"{stats['HIGH_RISK']:,}", delta=None)
col3.metric("Medium Risk (Review)", f"{stats['MEDIUM_RISK']:,}", delta=None)
col4.metric("Low Risk (Allow)", f"{stats['LOW_RISK']:,}", delta=None)

st.divider()

# --- Tabs ---
tab1, tab2, tab3, tab4 = st.tabs(["Flagged Domains", "Domain Lookup", "Live Scoring", "Model Performance"])

# --- Tab 1: Flagged Domains ---
with tab1:
    st.subheader("High-Risk Domain Registrations")
    
    risk_filter = st.selectbox("Filter by Risk Tier", ["HIGH", "MEDIUM", "ALL"], index=0)
    
    if risk_filter == "ALL":
        where_clause = "WHERE risk_tier IN ('HIGH', 'MEDIUM')"
    else:
        where_clause = f"WHERE risk_tier = '{risk_filter}'"
    
    flagged_df = session.sql(f"""
        SELECT 
            domain_name || '.org' as domain,
            registrant_org,
            registrant_country as country,
            ROUND(ml_confidence * 100, 1) as confidence_pct,
            risk_tier,
            recommended_action,
            registration_date::DATE as registered
        FROM DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.DOMAIN_RISK_SCORES
        {where_clause}
        ORDER BY ml_confidence DESC
        LIMIT 100
    """).to_pandas()
    
    st.dataframe(flagged_df, use_container_width=True)
    st.caption(f"Showing top 100 of {stats['HIGH_RISK'] + stats['MEDIUM_RISK']:,} flagged domains")

# --- Tab 2: Domain Lookup ---
with tab2:
    st.subheader("Investigate a Domain")
    
    domain_input = st.text_input("Enter domain name (without .org)", placeholder="e.g., amaz0n-secure")
    
    if domain_input:
        result = session.sql(f"""
            SELECT 
                r.domain_name || '.org' as domain,
                r.registrant_org,
                r.registrant_country,
                r.registration_date::DATE as registered,
                r.whois_privacy,
                r.domains_by_registrant,
                r.has_website_content,
                r.website_category,
                s.ml_confidence,
                s.risk_tier,
                s.recommended_action
            FROM DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.RAW_REGISTRATIONS r
            LEFT JOIN DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.DOMAIN_RISK_SCORES s ON r.domain_id = s.domain_id
            WHERE r.domain_name ILIKE '%{domain_input}%'
            LIMIT 10
        """).to_pandas()
        
        if len(result) > 0:
            for _, row in result.iterrows():
                risk_color = {"HIGH": "red", "MEDIUM": "orange", "LOW": "green"}.get(row["RISK_TIER"], "gray")
                st.markdown(f"### :{risk_color}[{row['RISK_TIER']}] — {row['DOMAIN']}")
                
                c1, c2, c3 = st.columns(3)
                c1.metric("Confidence", f"{row['ML_CONFIDENCE']*100:.1f}%")
                c2.metric("Registrant Domains", row['DOMAINS_BY_REGISTRANT'])
                c3.metric("Action", row['RECOMMENDED_ACTION'])
                
                st.json({
                    "registrant_org": row["REGISTRANT_ORG"],
                    "country": row["REGISTRANT_COUNTRY"],
                    "registered": str(row["REGISTERED"]),
                    "whois_privacy": bool(row["WHOIS_PRIVACY"]),
                    "has_website": bool(row["HAS_WEBSITE_CONTENT"]),
                    "website_category": row["WEBSITE_CATEGORY"],
                })
                
                # Run Cortex AI analysis
                with st.spinner("Running AI analysis..."):
                    ai_result = session.sql(f"""
                        SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large2',
                            'You are a domain abuse analyst. Assess this domain: '
                            || 'Domain: {row["DOMAIN"]}, '
                            || 'Registrant: {row["REGISTRANT_ORG"]}, '
                            || 'Country: {row["REGISTRANT_COUNTRY"]}, '
                            || 'WHOIS Privacy: {row["WHOIS_PRIVACY"]}, '
                            || 'Domains owned: {row["DOMAINS_BY_REGISTRANT"]}. '
                            || 'Give a 2-3 sentence risk assessment.'
                        ) as assessment
                    """).to_pandas().iloc[0]["ASSESSMENT"]
                    st.info(f"**AI Assessment:** {ai_result}")
                st.divider()
        else:
            st.warning("No matching domains found.")

# --- Tab 3: Live Scoring ---
with tab3:
    st.subheader("Score a New Domain Registration")
    st.caption("Simulate scoring a new domain through the pipeline")
    
    with st.form("scoring_form"):
        sc1, sc2 = st.columns(2)
        new_domain = sc1.text_input("Domain Name", value="paypal-secure-login")
        new_org = sc2.text_input("Registrant Org", value="Quick Digital LLC")
        sc3, sc4 = st.columns(2)
        new_country = sc3.selectbox("Country", ["US", "CA", "GB", "RU", "CN", "NG", "UA", "VN"])
        new_bulk = sc4.number_input("Domains by Registrant", min_value=1, max_value=500, value=45)
        sc5, sc6 = st.columns(2)
        new_privacy = sc5.checkbox("WHOIS Privacy", value=True)
        new_content = sc6.checkbox("Has Website Content", value=False)
        
        submitted = st.form_submit_button("Score Domain", type="primary")
    
    if submitted:
        # Compute features inline
        import re
        name_length = len(new_domain)
        digit_count = len(re.findall(r'[0-9]', new_domain))
        hyphen_count = new_domain.count('-')
        brand_kw = 1 if re.search(r'(paypal|amazon|microsoft|apple|google|netflix|facebook|chase)', new_domain) else 0
        leet = 1 if re.search(r'(paypa1|amaz0n|g00gle|micros0ft|app1e|netf1ix|faceb00k)', new_domain) else 0
        phish_kw = 1 if re.search(r'(secure|login|verify|account|update|official|alert)', new_domain) else 0
        scam_kw = 1 if re.search(r'(free|prize|reward|gift|money|crypto|bitcoin|loan|cash)', new_domain) else 0
        digit_ratio = digit_count / max(name_length, 1)
        high_risk = 1 if new_country in ('RU','CN','NG','UA','RO','VN','PH','ID') else 0
        
        score_result = session.sql(f"""
            SELECT DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.BAD_DOMAIN_CLASSIFIER_GBM!PREDICT_PROBA(
                NAME_LENGTH => {name_length},
                DIGIT_COUNT => {digit_count},
                HYPHEN_COUNT => {hyphen_count},
                WORD_COUNT => {hyphen_count},
                BRAND_KEYWORD_PRESENT => {brand_kw},
                LEETSPEAK_SUBSTITUTION => {leet},
                PHISHING_KEYWORD_PRESENT => {phish_kw},
                SCAM_KEYWORD_PRESENT => {scam_kw},
                DIGIT_RATIO => {digit_ratio:.4f},
                DOMAINS_BY_REGISTRANT => {new_bulk},
                BULK_REGISTRANT_FLAG => {1 if new_bulk >= 10 else 0},
                MASS_REGISTRANT_FLAG => {1 if new_bulk >= 50 else 0},
                WHOIS_PRIVACY_FLAG => {1 if new_privacy else 0},
                NO_CONTENT_FLAG => {0 if new_content else 1},
                PRIVACY_NO_CONTENT_COMBO => {1 if new_privacy and not new_content else 0},
                HIGH_RISK_COUNTRY => {high_risk},
                ANONYMOUS_EMAIL_FLAG => 0,
                SUSPICIOUS_NAMESERVER_FLAG => 0,
                WEBSITE_RISK_SCORE => 0
            ):"output_feature_1"::FLOAT as confidence
        """).to_pandas().iloc[0]["CONFIDENCE"]
        
        risk_tier = "HIGH" if score_result >= 0.85 else ("MEDIUM" if score_result >= 0.5 else "LOW")
        action = "BLOCK" if risk_tier == "HIGH" else ("REVIEW" if risk_tier == "MEDIUM" else "ALLOW")
        
        st.markdown("---")
        rc1, rc2, rc3 = st.columns(3)
        risk_color = {"HIGH": "red", "MEDIUM": "orange", "LOW": "green"}[risk_tier]
        rc1.metric("Risk Tier", risk_tier)
        rc2.metric("Confidence", f"{score_result*100:.1f}%")
        rc3.metric("Action", action)
        
        if risk_tier in ("HIGH", "MEDIUM"):
            st.error(f"**{new_domain}.org** flagged as **{risk_tier} RISK** — recommended action: **{action}**")
        else:
            st.success(f"**{new_domain}.org** appears legitimate — **ALLOW**")

# --- Tab 4: Model Performance ---
with tab4:
    st.subheader("Classification Model Performance")
    st.caption("GradientBoosting model registered in Snowflake Model Registry")
    
    mc1, mc2 = st.columns(2)
    with mc1:
        st.markdown("**Suspicious Domain Detection**")
        st.metric("Precision", "97.4%")
        st.metric("Recall", "97.1%")
        st.metric("F1 Score", "97.3%")
    
    with mc2:
        st.markdown("**Legitimate Domain Detection**")
        st.metric("Precision", "99.0%")
        st.metric("Recall", "99.1%")
        st.metric("F1 Score", "99.0%")
    
    st.divider()
    st.subheader("Model Details")
    
    st.markdown("""
    | Property | Value |
    |---|---|
    | **Model Name** | `BAD_DOMAIN_CLASSIFIER_GBM` |
    | **Version** | V1 |
    | **Algorithm** | GradientBoostingClassifier (sklearn) |
    | **Features** | 19 domain risk signals |
    | **Training Rows** | 10,000 |
    """)
    
    st.subheader("Risk Tier Distribution")
    tier_df = session.sql("""
        SELECT risk_tier, COUNT(*) as count
        FROM DOMAIN_RISK_DEMO.BAD_DOMAIN_ML.DOMAIN_RISK_SCORES
        GROUP BY 1
        ORDER BY count DESC
    """).to_pandas()
    st.bar_chart(tier_df.set_index("RISK_TIER")["COUNT"])

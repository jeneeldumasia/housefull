FROM grafana/grafana:13.3.0

COPY provisioning /etc/grafana/provisioning
COPY dashboards /etc/grafana/housefull-dashboards
COPY start.sh /start.sh

# Public and read-only: anyone can view, and nobody can log in or change it.
ENV GF_AUTH_ANONYMOUS_ENABLED=true \
    GF_AUTH_ANONYMOUS_ORG_ROLE=Viewer \
    GF_AUTH_DISABLE_LOGIN_FORM=true \
    GF_AUTH_BASIC_ENABLED=false \
    GF_USERS_ALLOW_SIGN_UP=false \
    GF_EXPLORE_ENABLED=false \
    GF_UNIFIED_ALERTING_ENABLED=false \
    GF_ANALYTICS_REPORTING_ENABLED=false \
    GF_ANALYTICS_CHECK_FOR_UPDATES=false \
    GF_NEWS_NEWS_FEED_ENABLED=false \
    GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/tmp/housefull-dashboards/housefull.json

ENTRYPOINT ["/bin/sh", "/start.sh"]

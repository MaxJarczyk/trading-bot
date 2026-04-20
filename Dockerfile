FROM perl:5.38-slim

# Install curl (used for all Alpaca API calls)
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY orb_bot.pl .

RUN chmod +x orb_bot.pl

CMD ["perl", "orb_bot.pl"]

FROM alpine:3.21

RUN apk add --no-cache curl jq findutils bash

COPY poll.sh /poll.sh
RUN chmod +x /poll.sh

ENTRYPOINT ["/poll.sh"]

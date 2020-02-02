FROM alpine

WORKDIR /app

ADD https://storage.googleapis.com/kubernetes-release/release/v1.17.0/bin/linux/amd64/kubectl /usr/local/bin

ADD run.sh /app

RUN chmod +x /usr/local/bin/kubectl
RUN chmod +x /app/run.sh
CMD [ "/app/run.sh" ]
FROM alpine:3.11

RUN apk add --no-cache openssh openrc ansible git sshpass vim

RUN mkdir -p /root/.ssh

CMD ["sh"]
from maven:3-jdk-8

MAINTAINER daniel.petisme@gmail.com <Daniel Petisme>

ADD pom.xml /pom.xml
RUN mvn dependency:go-offline

ADD src /src
RUN mvn compile

EXPOSE 8080

CMD mvn exec:java
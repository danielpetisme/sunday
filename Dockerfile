from maven:3-jdk-8

MAINTAINER daniel.petisme@gmail.com <Daniel Petisme>

ADD pom.xml /pom.xml
RUN mvn dependency:go-offline

ADD src /src
RUN mvn package

VOLUME /tmp

EXPOSE 8080

CMD java -jar /target/sunday-0.0.1-SNAPSHOT-jar-with-dependencies.jar
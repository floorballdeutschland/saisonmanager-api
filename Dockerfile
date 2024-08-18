FROM ruby:3.1

RUN apt-get update -qq && apt-get install -y nodejs postgresql-client

ENV RAILS_ROOT /app
RUN mkdir -p $RAILS_ROOT

WORKDIR $RAILS_ROOT

# Gems:
COPY Gemfile Gemfile
COPY Gemfile.lock Gemfile.lock
RUN bundle install

RUN echo "source ~/.aliases" >> ~/.bashrc


COPY . /app

EXPOSE 3000

CMD ["rails", "server", "-b", "0.0.0.0"]

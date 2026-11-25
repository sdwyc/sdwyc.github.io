# frozen_string_literal: true

# Renders the Google Scholar citation count for one bibliography entry.
#
# Counts come from _data/scholar_citations.yml, so the build never touches
# scholar.google.com (the per-article endpoint answers with an anti-bot
# redirect, which is why this used to render N/A everywhere).
#
# Refresh the cache with:  python3 bin/update_scholar_citations.py
module Jekyll
  class GoogleScholarCitationsTag < Liquid::Tag
    @warned = []

    class << self
      attr_reader :warned
    end

    def initialize(tag_name, params, tokens)
      super
      @userid_expr, @article_expr = params.split(" ").map(&:strip)
    end

    def render(context)
      userid = resolve(context, @userid_expr)
      article = resolve(context, @article_expr)

      counts = context.registers[:site].data.dig("scholar_citations", userid)
      value = counts && counts[article]

      if value.nil?
        warn_once("#{userid}/#{article} is not in _data/scholar_citations.yml " \
                  "(run bin/update_scholar_citations.py)")
        return "N/A"
      end

      value.to_i
    end

    private

    # Accepts both plain variables ("site.scholar_userid") and dotted paths
    # ("entry.google_scholar_id").
    def resolve(context, expr)
      value = Liquid::VariableLookup.new(expr).evaluate(context)
      (value.nil? ? expr : value).to_s.strip
    end

    def warn_once(message)
      return if self.class.warned.include?(message)

      self.class.warned << message
      Jekyll.logger.warn "Scholar:", message
    end
  end
end

Liquid::Template.register_tag("google_scholar_citations", Jekyll::GoogleScholarCitationsTag)

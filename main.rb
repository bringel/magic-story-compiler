# frozen_string_literal: true
require 'capybara/dsl'

class MagicStoryCompiler
  include Capybara::DSL

  Capybara.default_driver = :selenium_chrome

  def initialize()
    visit("https://magic.wizards.com/en/story")
  end

  def get_article_links(set_name:)
    find_set_element(set_name: set_name).click

    find_story_switch_buttons.flat_map do |b|
      b.click
      find_article_elements.map do |el|
        title = el.find('h3').text(:all)
        link = el.find('a[aria-label="Read More"]')

        {
          title: title,
          url: link['href']
        }
      end
    end
  end

  def find_story_switch_buttons()
    [
      find_story_archive.find_button("Magic Story"),
      find_story_archive.find_button("Side Stories")
    ]
  end
  
  def find_article_elements
    find_story_archive.all('article')
  end
  
  def find_set_element(set_name:)
    sets = find_set_slider
    years = find_year_slider

    years.all("span.swiper-slide").each do |y|
      y.click
      begin
        set = sets.find("div.swiper-slide", text: set_name) 
      rescue Capybara::ElementNotFound
        next
      end
      return set if set
    end
  end

  def find_year_slider()
    scroll_to(find_story_archive)
    has_selector?("section#story-arcive div.swiper-wrapper")     
    sliders = all("section#story-archive div.swiper-wrapper")
  
    sliders.find { |s| s.all("span", text: 2023).length > 0 }
  end

  def find_set_slider()
    scroll_to(find_story_archive)
    has_selector?("section#story-arcive div.swiper-wrapper")     
    sliders = all("section#story-archive div.swiper-wrapper")

    sliders.reject { |s| s.all("span", text: 2023).length > 0 }.first
  end

  def find_story_archive
    find("section#story-archive")
  end
end
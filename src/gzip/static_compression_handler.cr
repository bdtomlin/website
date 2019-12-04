class Lucky::StaticCompressionHandler
  Habitat.create do
    setting serve_precompressed_assets : Bool = false
  end

  include HTTP::Handler

  GZIP_FILE_EXTENSIONS = %w(.htm .html .txt .css .js .svg .json .xml .otf .ttf .woff .woff2)

  def initialize(@public_dir : String, @file_ext = "gz", @content_encoding = "gzip")
  end

  def call(context)
    original_path = context.request.path.not_nil!
    request_path = URI.decode(original_path)
    expanded_path = File.expand_path(request_path, "/")
    file_path = File.join(@public_dir, expanded_path)
    compressed_path = "#{file_path}.#{@file_ext}"

    if !should_gzip?(file_path, compressed_path, context.request.headers)
      call_next(context)
      return
    end

    context.response.headers["Content-Encoding"] = @content_encoding

    last_modified = modification_time(compressed_path)
    add_cache_headers(context.response.headers, last_modified)

    if cache_request?(context, last_modified)
      context.response.status = :not_modified
      return
    end

    context.response.content_type = MIME.from_filename(file_path, "application/octet-stream")
    context.response.content_length = File.size(compressed_path)
    File.open(compressed_path) do |file|
      IO.copy(file, context.response)
    end
  end

  private def should_gzip?(file_path, compressed_path, request_headers)
    settings.serve_precompressed_assets &&
      request_headers.includes_word?("Accept-Encoding", @content_encoding) &&
      GZIP_FILE_EXTENSIONS.includes?(File.extname(file_path)) &&
      File.exists?(compressed_path)
  end

  private def add_cache_headers(response_headers : HTTP::Headers, last_modified : Time) : Nil
    response_headers["Etag"] = etag(last_modified)
    response_headers["Last-Modified"] = HTTP.format_time(last_modified)
  end

  private def cache_request?(context : HTTP::Server::Context, last_modified : Time) : Bool
    # According to RFC 7232:
    # A recipient must ignore If-Modified-Since if the request contains an If-None-Match header field
    if if_none_match = context.request.if_none_match
      match = {"*", context.response.headers["Etag"]}
      if_none_match.any? { |etag| match.includes?(etag) }
    elsif if_modified_since = context.request.headers["If-Modified-Since"]?
      header_time = HTTP.parse_time(if_modified_since)
      # File mtime probably has a higher resolution than the header value.
      # An exact comparison might be slightly off, so we add 1s padding.
      # Static files should generally not be modified in subsecond intervals, so this is perfectly safe.
      # This might be replaced by a more sophisticated time comparison when it becomes available.
      !!(header_time && last_modified <= header_time + 1.second)
    else
      false
    end
  end

  private def etag(modification_time)
    %{W/"#{modification_time.to_unix}"}
  end

  private def modification_time(file_path)
    File.info(file_path).modification_time
  end
end

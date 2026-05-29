# frozen_string_literal: true

# PuranOS runtime customizations for the self-hosted DocuSeal Community container.
#
# Adds:
#   1. Document-ingestion API routes for PDF, DOCX, DOC, and HTML inputs. The
#      final persistence path delegates attachment processing and submission
#      creation to DocuSeal's shipped open-source services.
#   2. A Rack middleware that injects an AGPL §13 Corresponding Source offer
#      into HTML responses, satisfying the network-interaction source-offer
#      requirement for this modified version of DocuSeal Community.

require 'base64'
require 'cgi'
require 'fileutils'
require 'open3'
require 'securerandom'
require 'stringio'
require 'tempfile'
require 'tmpdir'
require 'uri'

module PuranWaterDocusealCustomizations
  LOG_PREFIX = '[puran-water-docuseal-customizations]'
  DEFAULT_ROLE_NAME = 'Submitter'
  PDF_CONTENT_TYPE = 'application/pdf'
  DOCX_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  DOC_CONTENT_TYPE = 'application/msword'
  HTML_CONTENT_TYPE = 'text/html'
  DATA_URI_REGEXP = %r{\Adata:[^;,]+;base64,}i
  URL_REGEXP = %r{\Ahttps?://}i
  FIELD_TAG_REGEXP = /\{\{([^{}]+)\}\}/

  FORMAT_CONFIGS = {
    pdf: {
      extension: '.pdf',
      content_type: PDF_CONTENT_TYPE,
      fallback_name: 'API PDF Template',
      template_controller: :PuranWaterPdfTemplatesController,
      submission_controller: :PuranWaterPdfSubmissionsController
    },
    docx: {
      extension: '.docx',
      content_type: DOCX_CONTENT_TYPE,
      fallback_name: 'API DOCX Template',
      template_controller: :PuranWaterDocxTemplatesController,
      submission_controller: :PuranWaterDocxSubmissionsController
    },
    doc: {
      extension: '.doc',
      content_type: DOC_CONTENT_TYPE,
      fallback_name: 'API DOC Template',
      template_controller: :PuranWaterDocTemplatesController
    },
    html: {
      extension: '.html',
      content_type: HTML_CONTENT_TYPE,
      fallback_name: 'API HTML Template',
      template_controller: :PuranWaterHtmlTemplatesController,
      submission_controller: :PuranWaterHtmlSubmissionsController
    }
  }.freeze

  API_ROUTES = [
    ['templates/pdf', 'puran_water_pdf_templates#create'],
    ['submissions/pdf', 'puran_water_pdf_submissions#create'],
    ['templates/docx', 'puran_water_docx_templates#create'],
    ['templates/doc', 'puran_water_doc_templates#create'],
    ['submissions/docx', 'puran_water_docx_submissions#create'],
    ['templates/html', 'puran_water_html_templates#create'],
    ['submissions/html', 'puran_water_html_submissions#create']
  ].freeze

  FIELD_TYPES = %w[
    heading text signature initials date number image checkbox multiple file
    radio select cells stamp payment phone verification strikethrough
  ].freeze

  REQUIRED_CONSTANTS = %w[
    Api::ApiBaseController
    ActionDispatch::Http::UploadedFile
    HexaPDF
    Pdfium
    Template
    TemplateFolders
    Templates::CreateAttachments
    Templates::CreateAttachments::InvalidFileType
    Templates::CreateAttachments::PdfEncrypted
    Templates::ProcessDocument
    Templates::SerializeForApi
    Submissions
    Submissions::CreateFromSubmitters
    Submissions::CreateFromSubmitters::BaseError
    Submissions::SerializeForApi
    Submission
    Submitters
    Submitters::NormalizeValues
    Submitters::NormalizeValues::BaseError
    Submitters::SerializeForApi
    DownloadUtils
    DownloadUtils::UnableToDownload
  ].freeze

  REQUIRED_METHODS = {
    'DownloadUtils' => %i[call],
    'Submissions' => %i[create_from_submitters],
    'Submissions::SerializeForApi' => %i[call],
    'Submitters::SerializeForApi' => %i[call],
    'Templates::CreateAttachments' => %i[call],
    'Templates::ProcessDocument' => %i[normalize_attachment_fields],
    'Templates::SerializeForApi' => %i[call]
  }.freeze

  InvalidRequest = Class.new(StandardError)
  MissingDependency = Class.new(StandardError)

  module_function

  def install!
    missing = missing_constants

    if missing.present?
      log("not installing routes; missing constants: #{missing.join(', ')}")
      return false
    end

    missing = missing_methods

    if missing.present?
      log("not installing routes; missing methods: #{missing.join(', ')}")
      return false
    end

    define_controllers!
    append_routes!
    true
  rescue StandardError => e
    log("initializer no-op after install failure: #{e.class}: #{e.message}", e)
    false
  end

  def missing_constants
    REQUIRED_CONSTANTS.reject { |name| name.safe_constantize }
  rescue StandardError => e
    log("constant probe failed: #{e.class}: #{e.message}", e)
    REQUIRED_CONSTANTS
  end

  def missing_methods
    REQUIRED_METHODS.flat_map do |constant_name, method_names|
      constant = constant_name.safe_constantize
      method_names.reject { |method_name| constant.respond_to?(method_name) }
                  .map { |method_name| "#{constant_name}.#{method_name}" }
    end
  rescue StandardError => e
    log("method probe failed: #{e.class}: #{e.message}", e)
    REQUIRED_METHODS.flat_map { |constant_name, method_names| method_names.map { |name| "#{constant_name}.#{name}" } }
  end

  def define_controllers!
    base_controller = 'Api::ApiBaseController'.safe_constantize
    raise MissingDependency, 'Api::ApiBaseController missing' unless base_controller

    FORMAT_CONFIGS.each do |format, config|
      define_template_controller!(base_controller, config.fetch(:template_controller), format)

      next unless config[:submission_controller]

      define_submission_controller!(base_controller, config.fetch(:submission_controller), format)
    end
  end

  def define_template_controller!(base_controller, class_name, format)
    return if "Api::#{class_name}".safe_constantize

    Api.const_set(class_name, Class.new(base_controller) do
      include PuranWaterDocusealCustomizations::ControllerMethods

      define_method(:api_document_format) { format }

      def create
        authorize!(:create, Template.new(account_id: current_user.account_id, author: current_user))

        template = build_api_template!(api_document_format)

        PuranWaterDocusealCustomizations.enqueue_created_template_hooks(template)

        render json: Templates::SerializeForApi.call(template)
      rescue PuranWaterDocusealCustomizations::InvalidRequest,
             Templates::CreateAttachments::InvalidFileType,
             Templates::CreateAttachments::PdfEncrypted,
             DownloadUtils::UnableToDownload => e
        render json: { error: e.message }, status: :unprocessable_content
      ensure
        cleanup_upload_tempfiles
      end
    end)
  end

  def define_submission_controller!(base_controller, class_name, format)
    return if "Api::#{class_name}".safe_constantize

    Api.const_set(class_name, Class.new(base_controller) do
      include PuranWaterDocusealCustomizations::ControllerMethods

      define_method(:api_document_format) { format }

      def create
        authorize!(:create, Template.new(account_id: current_user.account_id, author: current_user))
        authorize!(:create, Submission)

        template = build_api_template!(api_document_format)
        submissions = create_api_submissions!(template)
        submission = submissions.first

        PuranWaterDocusealCustomizations.enqueue_created_template_hooks(template)
        PuranWaterDocusealCustomizations.enqueue_created_submission_hooks(submissions)

        render json: PuranWaterDocusealCustomizations.serialize_submission_for_api(submission, params)
      rescue PuranWaterDocusealCustomizations::InvalidRequest,
             Templates::CreateAttachments::InvalidFileType,
             Templates::CreateAttachments::PdfEncrypted,
             Submitters::NormalizeValues::BaseError,
             Submissions::CreateFromSubmitters::BaseError,
             DownloadUtils::UnableToDownload => e
        render json: { error: e.message }, status: :unprocessable_content
      ensure
        cleanup_upload_tempfiles
      end
    end)
  end

  def append_routes!
    return unless Rails.application.routes.respond_to?(:append)

    missing_routes = missing_api_routes
    return if missing_routes.blank?

    Rails.application.routes.append do
      namespace :api, defaults: { format: :json } do
        missing_routes.each do |route_path, target|
          post route_path, to: target
        end
      end
    end

    # install! runs from an after_initialize hook (see bottom of file), i.e. after
    # the route set has already been drawn — so the appended block only takes
    # effect once routes are reloaded.
    Rails.application.reload_routes! if Rails.application.respond_to?(:reload_routes!)
  end

  def routes_already_present?
    missing_api_routes.empty?
  rescue StandardError
    false
  end

  def missing_api_routes
    existing_paths = Rails.application.routes.routes.filter_map do |route|
      route.path.spec.to_s if route.verb == 'POST'
    end

    API_ROUTES.reject do |path, _target|
      existing_paths.include?("/api/#{path}(.:format)")
    end
  rescue StandardError
    API_ROUTES
  end

  def enqueue_created_template_hooks(template)
    WebhookUrls.enqueue_events(template, 'template.created') if defined?(WebhookUrls)
    SearchEntries.enqueue_reindex(template) if defined?(SearchEntries)
  rescue StandardError => e
    log("template hook failure for template #{template.id}: #{e.class}: #{e.message}", e)
  end

  def enqueue_created_submission_hooks(submissions)
    WebhookUrls.enqueue_events(submissions, 'submission.created') if defined?(WebhookUrls)

    Submissions.send_signature_requests(submissions)

    submissions.each do |submission|
      submission.submitters.each do |submitter|
        next unless submitter.completed_at?

        ProcessSubmitterCompletionJob.perform_async('submitter_id' => submitter.id,
                                                    'send_invitation_email' => false)
      end
    end

    SearchEntries.enqueue_reindex(submissions) if defined?(SearchEntries)
  rescue StandardError => e
    log("submission hook failure: #{e.class}: #{e.message}", e)
  end

  def serialize_submission_for_api(submission, params)
    json = Submissions::SerializeForApi.call(
      submission,
      submission.submitters,
      params,
      with_events: false,
      with_documents: true,
      with_values: true
    )

    json['schema'] = submission.template_schema || submission.template.schema
    json['fields'] = submission.template_fields || submission.template.fields
    json['submitters'] = submission.submitters.map do |submitter|
      Submitters::SerializeForApi.call(
        submitter,
        with_documents: false,
        with_urls: true,
        with_values: true,
        params:
      )
    end
    json
  end

  def log(message, error = nil)
    Rails.logger.warn("#{LOG_PREFIX} #{message}") if defined?(Rails) && Rails.respond_to?(:logger)
    Rollbar.warning(error || "#{LOG_PREFIX} #{message}") if defined?(Rollbar)
  rescue StandardError
    nil
  end

  module ControllerMethods
    def build_api_template!(format = :pdf)
      payload = api_payload
      document_params = document_params_for(format, payload)
      raise InvalidRequest, 'documents are required' if document_params.blank?

      prepared_documents = prepare_documents(document_params, format)
      role_names = build_role_names(payload, document_params, prepared_documents)
      submitters = role_names.map { |name| { 'uuid' => SecureRandom.uuid, 'name' => name } }

      template = find_or_initialize_template(payload, document_params, format)
      template.submitters = submitters
      template.fields = []
      template.schema = []
      template.save!

      uploaded_files = prepared_documents.map { |document| document.fetch(:uploaded_file) }
      documents, = Templates::CreateAttachments.call(template, { files: uploaded_files, password: payload['password'] },
                                                     extract_fields: true)
      raise InvalidRequest, "no #{format.to_s.upcase} documents were created" if documents.blank?

      schema = build_schema(documents, document_params)
      auto_fields = Templates::ProcessDocument.normalize_attachment_fields(template, documents)
      tag_fields = build_tag_fields(prepared_documents, submitters, schema)
      explicit_fields = build_explicit_fields(document_params, submitters, schema)

      template.update!(
        schema:,
        fields: auto_fields + tag_fields + explicit_fields,
        submitters:
      )

      template
    end

    def create_api_submissions!(template)
      payload = api_payload
      submitters = normalize_submission_submitters(payload, template)
      raise InvalidRequest, 'submitters are required' if submitters.blank?

      params_hash = normalize_submission_params(payload, submitters)
      order = (payload['submitters_order'].presence || payload['order'].presence || 'preserved').to_s

      submissions = Submissions.create_from_submitters(
        template:,
        user: current_user,
        source: :api,
        submitters_order: order,
        submissions_attrs: {
          name: payload['name'],
          expire_at: payload['expire_at'],
          variables: payload['variables'],
          submitters:
        }.compact.with_indifferent_access,
        params: params_hash
      )

      raise InvalidRequest, 'no valid submitters provided' if submissions.blank?

      submissions
    end

    def api_payload
      @api_payload ||=
        params.to_unsafe_h
              .except('controller', 'action', 'format')
              .deep_stringify_keys
    end

    def document_params_for(format, payload)
      documents = Array.wrap(payload['documents'])

      if format == :html && documents.blank? && payload['html'].present?
        documents = [{
          'name' => payload['name'].presence || 'document.html',
          'html' => payload['html'],
          'html_header' => payload['html_header'],
          'html_footer' => payload['html_footer']
        }]
      end

      documents
    end

    def find_or_initialize_template(payload, document_params, format)
      external_id = payload['external_id'].presence || payload['application_key'].presence
      template = external_id ? current_account.templates.find_or_initialize_by(external_id:) : current_account.templates.new

      config = FORMAT_CONFIGS.fetch(format)
      template.author = current_user
      template.account = current_account
      template.folder = TemplateFolders.find_or_create_by_name(current_user, payload['folder_name'])
      template.name = payload['name'].presence || File.basename(document_params.first['name'].to_s, '.*').presence ||
                      config.fetch(:fallback_name)
      template.source = 'api'
      template.shared_link = payload.key?('shared_link') ? truthy?(payload['shared_link']) : true

      Templates.maybe_assign_access(template) if defined?(Templates) && Templates.respond_to?(:maybe_assign_access)

      template
    end

    def prepare_documents(document_params, format)
      document_params.map.with_index do |document, index|
        document = document.to_h.deep_stringify_keys

        case format
        when :pdf
          prepare_pdf_document(document, index)
        when :docx, :doc
          prepare_office_document(document, index, format)
        when :html
          prepare_html_document(document, index)
        else
          raise InvalidRequest, "unsupported document format: #{format}"
        end
      end
    end

    def prepare_pdf_document(document, index)
      source_name = document['name'].presence || "document-#{index + 1}.pdf"
      pdf_bytes = read_document_data(document, index)

      {
        source_format: :pdf,
        source_name:,
        uploaded_file: uploaded_file_from_bytes(
          pdf_bytes,
          ensure_extension(source_name, '.pdf', fallback: "document-#{index + 1}.pdf", replace_extension: true),
          PDF_CONTENT_TYPE
        ),
        field_tags: extract_pdf_field_tags(pdf_bytes)
      }
    end

    def prepare_office_document(document, index, format)
      config = FORMAT_CONFIGS.fetch(format)
      source_name = document['name'].presence || "document-#{index + 1}#{config.fetch(:extension)}"
      source_bytes = read_document_data(document, index)
      source_tempfile = write_upload_tempfile(source_bytes, config.fetch(:extension))

      source_text =
        if format == :docx
          extract_docx_text(source_tempfile)
        else
          source_bytes.to_s.force_encoding('UTF-8').scrub
        end

      pdf_bytes = convert_office_document_to_pdf(source_tempfile, source_name)

      {
        source_format: format,
        source_name:,
        uploaded_file: uploaded_file_from_bytes(
          pdf_bytes,
          ensure_extension(source_name, '.pdf', fallback: "document-#{index + 1}.pdf", replace_extension: true),
          PDF_CONTENT_TYPE
        ),
        field_tags: position_field_tags(parse_field_tags(source_text), pdf_bytes)
      }
    end

    def prepare_html_document(document, index)
      source_name = document['name'].presence || "document-#{index + 1}.html"
      html = html_document_body(document, index)
      pdf_bytes = render_html_document_to_pdf(html, source_name)

      {
        source_format: :html,
        source_name:,
        uploaded_file: uploaded_file_from_bytes(
          pdf_bytes,
          ensure_extension(source_name, '.pdf', fallback: "document-#{index + 1}.pdf", replace_extension: true),
          PDF_CONTENT_TYPE
        ),
        field_tags: position_field_tags(parse_field_tags(html_to_text(html)), pdf_bytes)
      }
    end

    def html_document_body(document, index)
      html = document['html'].presence || document['content'].presence

      if html.blank?
        data = read_document_data(document, index)
        html = data.to_s.force_encoding('UTF-8').scrub
      end

      html = [document['html_header'], html, document['html_footer']].compact_blank.join("\n")
      raise InvalidRequest, "documents[#{index}].html or documents[#{index}].file is required" if html.blank?

      html
    end

    def read_document_data(document, index)
      file = document['file'].presence || document['url'].presence
      raise InvalidRequest, "documents[#{index}].file is required" if file.blank?

      if file.match?(URL_REGEXP)
        DownloadUtils.call(file, validate: true).body
      else
        Base64.decode64(file.to_s.sub(DATA_URI_REGEXP, ''))
      end
    rescue ArgumentError
      raise InvalidRequest, "documents[#{index}].file is not valid base64"
    end

    def uploaded_file_from_bytes(bytes, filename, content_type)
      ActionDispatch::Http::UploadedFile.new(
        tempfile: write_upload_tempfile(bytes, File.extname(filename).presence || '.pdf'),
        filename:,
        type: content_type
      )
    end

    def write_upload_tempfile(bytes, extension = '.pdf')
      tempfile = new_upload_tempfile(extension)
      tempfile.write(bytes)
      tempfile.rewind
      tempfile
    end

    def new_upload_tempfile(extension = '.pdf')
      tempfile = Tempfile.new(['docuseal-api-upload', extension])
      tempfile.binmode
      upload_tempfiles << tempfile
      tempfile
    end

    def upload_tempfiles
      @puran_water_docuseal_upload_tempfiles ||= []
    end

    def cleanup_upload_tempfiles
      upload_tempfiles.each { |tempfile| tempfile.close! if tempfile.respond_to?(:close!) }
    rescue StandardError => e
      PuranWaterDocusealCustomizations.log("tempfile cleanup failed: #{e.class}: #{e.message}", e)
    ensure
      @puran_water_docuseal_upload_tempfiles = []
    end

    def ensure_extension(name, extension, fallback:, replace_extension: false)
      filename = File.basename(name.to_s.presence || fallback)
      filename = fallback if filename.blank? || filename == '.'

      if replace_extension
        base = File.basename(filename, '.*').presence || File.basename(fallback, '.*')
        "#{base}#{extension}"
      elsif File.extname(filename).casecmp(extension).zero?
        filename
      else
        "#{filename}#{extension}"
      end
    end

    def convert_office_document_to_pdf(source_tempfile, source_name)
      converter = office_converter_command
      raise InvalidRequest, 'DOCX/DOC conversion requires libreoffice or soffice in the DocuSeal container' if converter.blank?

      output_dir = Dir.mktmpdir('docuseal-api-office-pdf')
      stdout, stderr, status = Open3.capture3(
        converter,
        '--headless',
        '--nologo',
        '--nodefault',
        '--nofirststartwizard',
        '--convert-to',
        'pdf',
        '--outdir',
        output_dir,
        source_tempfile.path
      )

      unless status.success?
        raise InvalidRequest,
              "failed to convert #{source_name} to PDF: #{[stderr, stdout].join("\n").strip.presence || status}"
      end

      output_path = Dir[File.join(output_dir, '*.pdf')].first
      raise InvalidRequest, "failed to convert #{source_name} to PDF" if output_path.blank?

      File.binread(output_path)
    ensure
      FileUtils.remove_entry(output_dir) if output_dir.present? && Dir.exist?(output_dir)
    end

    def office_converter_command
      candidates = [
        ENV['DOCUSEAL_OFFICE_CONVERT_BIN'].presence,
        '/usr/bin/libreoffice',
        '/usr/local/bin/libreoffice',
        '/usr/bin/soffice',
        '/usr/local/bin/soffice',
        'libreoffice',
        'soffice'
      ].compact

      candidates.find do |candidate|
        if candidate.include?(File::SEPARATOR)
          File.executable?(candidate)
        else
          system('which', candidate, out: File::NULL, err: File::NULL)
        end
      end
    rescue StandardError => e
      PuranWaterDocusealCustomizations.log("office converter probe failed: #{e.class}: #{e.message}", e)
      nil
    end

    def extract_docx_text(tempfile)
      begin
        require 'zip' unless defined?(Zip::File)
      rescue LoadError => e
        PuranWaterDocusealCustomizations.log("DOCX text-tag parser skipped; rubyzip is unavailable: #{e.message}", e)
        return ''
      end

      unless defined?(Zip::File)
        PuranWaterDocusealCustomizations.log('DOCX text-tag parser skipped; Zip::File is unavailable')
        return ''
      end

      Zip::File.open(tempfile.path) do |zip|
        entry = zip.find_entry('word/document.xml')
        return '' unless entry

        xml = entry.get_input_stream.read
        xml = xml.gsub(%r{</w:p>}i, "\n").gsub(%r{<w:tab\s*/>}i, "\t")
        xml.scan(%r{<w:t\b[^>]*>(.*?)</w:t>}mi).map { |match| CGI.unescapeHTML(match.first) }.join
      end
    rescue StandardError => e
      PuranWaterDocusealCustomizations.log("DOCX text-tag parser failed: #{e.class}: #{e.message}", e)
      ''
    end

    def render_html_document_to_pdf(html, source_name)
      raise InvalidRequest, 'HTML ingestion requires HexaPDF in the DocuSeal container' unless defined?(HexaPDF)

      pdf = HexaPDF::Document.new
      page = pdf.pages.add
      canvas = page.canvas
      canvas.font('Helvetica', size: 12)

      margin = 72
      y = page.box.height - margin

      html_to_text(html).split(/\r?\n/).flat_map { |line| wrap_text_line(line) }.each do |line|
        if y < margin
          page = pdf.pages.add
          canvas = page.canvas
          canvas.font('Helvetica', size: 12)
          y = page.box.height - margin
        end

        canvas.text(line, at: [margin, y])
        y -= 18
      end

      io = StringIO.new
      pdf.write(io)
      io.string
    rescue InvalidRequest
      raise
    rescue StandardError => e
      raise InvalidRequest, "failed to render #{source_name} to PDF: #{e.message}"
    end

    def wrap_text_line(line)
      line = line.to_s.strip
      return [''] if line.blank?
      return [line] if line.length <= 110

      line.scan(/.{1,110}(?:\s+|\z)/).map(&:strip).presence || [line]
    end

    def html_to_text(html)
      html.to_s
          .gsub(%r{<br\s*/?>}i, "\n")
          .gsub(%r{</(p|div|h[1-6]|li|tr)>}i, "\n")
          .gsub(/<[^>]+>/, ' ')
          .then { |text| CGI.unescapeHTML(text) }
          .split("\n")
          .map { |line| line.gsub(/\s+/, ' ').strip }
          .reject(&:blank?)
          .join("\n")
    end

    def extract_pdf_field_tags(pdf_bytes)
      return [] unless defined?(Pdfium)

      tags = []
      Pdfium::Document.open_bytes(pdf_bytes) do |pdf|
        (0...pdf.page_count).each do |page_index|
          page = pdf.get_page(page_index)
          nodes = page.text_nodes
          text = nodes.map(&:content).join

          parse_field_tags(text).each do |tag|
            tag['areas'] = locate_tag_areas_on_page(nodes, text, tag['tag'], page_index)
            tags << tag
          end
        end
      end

      tags
    rescue StandardError => e
      PuranWaterDocusealCustomizations.log("PDF text-tag parser failed: #{e.class}: #{e.message}", e)
      []
    end

    def parse_field_tags(text)
      text.to_s.scan(FIELD_TAG_REGEXP).map.with_index do |match, index|
        raw = match.first.to_s
        parts = raw.split(';').map(&:strip).reject(&:blank?)
        name = parts.shift.presence || "Field #{index + 1}"
        attrs = parse_field_tag_attributes(parts)
        field_type = normalize_field_type(attrs['type'].presence || infer_field_tag_type(name))
        role = attrs['role'].presence || attrs['submitter'].presence || DEFAULT_ROLE_NAME

        {
          'tag' => "{{#{raw}}}",
          'uuid' => SecureRandom.uuid,
          'name' => name,
          'type' => field_type,
          'role' => role,
          'required' => attrs.key?('required') ? truthy?(attrs['required']) : true,
          'preferences' => field_tag_preferences(attrs)
        }.tap do |field|
          field['options'] = attrs['options'].to_s.split(',').map(&:strip).reject(&:blank?) if attrs['options'].present?
        end
      end
    end

    def parse_field_tag_attributes(parts)
      parts.each_with_object({}) do |part, attrs|
        key, value = part.split('=', 2)
        next if key.blank? || value.nil?

        attrs[key.strip.downcase] = value.to_s.strip
      end
    end

    def infer_field_tag_type(name)
      normalized = name.to_s.downcase

      return 'signature' if normalized.include?('signature') || normalized == 'sign'
      return 'initials' if normalized.include?('initial')
      return 'date' if normalized.match?(/\bdate\b/)
      return 'checkbox' if normalized.include?('checkbox')

      'text'
    end

    def normalize_field_type(value)
      type = value.to_s.downcase.tr('-', '_')
      FIELD_TYPES.include?(type) ? type : 'text'
    end

    def field_tag_preferences(attrs)
      attrs.each_with_object({}) do |(key, value), preferences|
        next if %w[type role submitter required options].include?(key)

        preferences[key] = value
      end
    end

    def position_field_tags(tags, pdf_bytes)
      return [] if tags.blank?
      return fallback_positioned_field_tags(tags) unless defined?(Pdfium)

      positioned = tags.map(&:dup)

      Pdfium::Document.open_bytes(pdf_bytes) do |pdf|
        used_indexes_by_page = Hash.new { |hash, key| hash[key] = [] }

        (0...pdf.page_count).each do |page_index|
          page = pdf.get_page(page_index)
          nodes = page.text_nodes
          text = nodes.map(&:content).join

          positioned.each do |tag|
            next if tag['areas'].present?

            tag_index = next_unused_tag_index(text, tag['tag'], used_indexes_by_page[page_index])
            next if tag_index.blank?

            used_indexes_by_page[page_index] << tag_index
            tag['areas'] = [area_from_text_nodes(nodes[tag_index, tag['tag'].length], page_index)]
          end
        end
      end

      fallback_positioned_field_tags(positioned)
    rescue StandardError => e
      PuranWaterDocusealCustomizations.log("text-tag positioning failed: #{e.class}: #{e.message}", e)
      fallback_positioned_field_tags(tags)
    end

    def next_unused_tag_index(text, tag, used_indexes)
      offset = 0

      loop do
        index = text.index(tag, offset)
        return nil if index.nil?
        return index unless used_indexes.include?(index)

        offset = index + tag.length
      end
    end

    def locate_tag_areas_on_page(nodes, text, tag, page_index)
      index = text.index(tag)
      return [] if index.blank?

      [area_from_text_nodes(nodes[index, tag.length], page_index)]
    end

    def area_from_text_nodes(nodes, page_index)
      nodes = Array.wrap(nodes).compact
      return fallback_area(0).merge('page' => page_index) if nodes.blank?

      x1 = nodes.map(&:x).min.to_f
      y1 = nodes.map(&:y).min.to_f
      x2 = nodes.map(&:endx).max.to_f
      y2 = nodes.map(&:endy).max.to_f

      x = clamp_ratio(x1)
      y = clamp_ratio(y1)
      w = clamp_ratio([x2 - x1, 0.08].max, max: 1.0 - x)
      h = clamp_ratio([y2 - y1, 0.025].max, max: 1.0 - y)

      { 'x' => x, 'y' => y, 'w' => w, 'h' => h, 'page' => page_index }
    end

    def fallback_positioned_field_tags(tags)
      tags.map.with_index do |tag, index|
        tag = tag.dup
        tag['areas'] = tag['areas'].presence || [fallback_area(index)]
        tag
      end
    end

    def fallback_area(index)
      { 'x' => 0.16, 'y' => 0.20 + ((index % 8) * 0.065), 'w' => 0.30, 'h' => 0.04, 'page' => 0 }
    end

    def clamp_ratio(value, min: 0.0, max: 1.0)
      [[value.to_f, min].max, max].min
    end

    def build_role_names(payload, document_params, prepared_documents)
      roles = []
      seen_roles = {}
      add_role = lambda do |value|
        role = value.to_s.strip
        next if role.blank? || seen_roles[role.downcase]

        roles << role
        seen_roles[role.downcase] = true
      end

      document_params.each do |document|
        Array.wrap(document['fields']).each { |field| add_role.call(field['role']) }
      end

      prepared_documents.each do |document|
        Array.wrap(document[:field_tags]).each { |field| add_role.call(field['role']) }
      end

      Array.wrap(payload['submitters']).each do |submitter|
        add_role.call(submitter['role'])
        Array.wrap(submitter['roles']).each { |submitter_role| add_role.call(submitter_role) }
      end

      roles.presence || [DEFAULT_ROLE_NAME]
    end

    def build_schema(documents, document_params)
      documents.map.with_index do |document, index|
        name = document_params.dig(index, 'name').presence || document.filename.base.to_s

        { 'attachment_uuid' => document.uuid, 'name' => File.basename(name, '.*') }
      end
    end

    def build_tag_fields(prepared_documents, submitters, schema)
      submitters_by_name = submitters.index_by { |submitter| submitter['name'].downcase }
      default_submitter = submitters.first

      prepared_documents.flat_map.with_index do |document, document_index|
        attachment_uuid = schema.dig(document_index, 'attachment_uuid')
        Array.wrap(document[:field_tags]).map.with_index do |field, field_index|
          build_field_hash(field, field_index, attachment_uuid, submitters_by_name, default_submitter)
        end
      end
    end

    def build_explicit_fields(document_params, submitters, schema)
      submitters_by_name = submitters.index_by { |submitter| submitter['name'].downcase }
      default_submitter = submitters.first

      document_params.flat_map.with_index do |document, document_index|
        attachment_uuid = schema.dig(document_index, 'attachment_uuid')
        Array.wrap(document['fields']).map.with_index do |field, field_index|
          build_field_hash(field, field_index, attachment_uuid, submitters_by_name, default_submitter)
        end
      end
    end

    def build_field_hash(field, field_index, attachment_uuid, submitters_by_name, default_submitter)
      type = normalize_field_type(field['type'].presence || 'text')
      raise InvalidRequest, "unsupported field type: #{type}" unless FIELD_TYPES.include?(type)

      role = field['role'].to_s.strip.presence || default_submitter['name']
      submitter = submitters_by_name[role.downcase] || default_submitter

      field_hash = {
        'uuid' => field['uuid'].presence || SecureRandom.uuid,
        'submitter_uuid' => submitter['uuid'],
        'name' => field['name'].presence || "#{type.titleize} #{field_index + 1}",
        'type' => type,
        'required' => field.key?('required') ? truthy?(field['required']) : true,
        'preferences' => field['preferences'].presence || {},
        'areas' => build_areas(field, attachment_uuid)
      }

      field_hash['title'] = field['title'] if field.key?('title')
      field_hash['description'] = field['description'] if field.key?('description')
      field_hash['readonly'] = truthy?(field['readonly']) if field.key?('readonly')
      field_hash['default_value'] = field['default_value'] if field.key?('default_value')
      field_hash['validation'] = field['validation'] if field['validation'].present?

      assign_options!(field_hash, field)

      field_hash
    end

    def build_areas(field, attachment_uuid)
      areas = Array.wrap(field['areas'])
      raise InvalidRequest, "field #{field['name'].presence || field['type']} areas are required" if areas.blank?

      areas.map do |area|
        page = Integer(area.fetch('page'))
        raise InvalidRequest, 'area page must be zero or greater' if page.negative?

        {
          'x' => Float(area.fetch('x')),
          'y' => Float(area.fetch('y')),
          'w' => Float(area.fetch('w')),
          'h' => Float(area.fetch('h')),
          'page' => page,
          'attachment_uuid' => attachment_uuid
        }.tap do |attrs|
          attrs['option'] = area['option'] if area['option'].present?
          attrs['cell_w'] = Float(area['cell_w']) if area['cell_w'].present?
        end
      rescue ArgumentError, KeyError
        raise InvalidRequest, "invalid area for field #{field['name'].presence || field['type']}"
      end
    end

    def assign_options!(field_hash, field)
      option_values = Array.wrap(field['options']).map do |option|
        option.is_a?(Hash) ? option['value'] : option
      end

      option_values += field_hash['areas'].filter_map { |area| area.delete('option') }
      option_values = option_values.map(&:to_s).reject(&:blank?).uniq

      return if option_values.blank?

      options = option_values.map { |value| { 'uuid' => SecureRandom.uuid, 'value' => value } }
      options_by_value = options.index_by { |option| option['value'] }

      field_hash['areas'].each do |area|
        option = field['areas'].to_a.find do |source_area|
          source_area['x'].to_f == area['x'].to_f &&
            source_area['y'].to_f == area['y'].to_f &&
            source_area['page'].to_i == area['page'].to_i
        end&.dig('option')

        area['option_uuid'] = options_by_value[option.to_s]['uuid'] if option.present? && options_by_value[option.to_s]
      end

      field_hash['options'] = options
    end

    def normalize_submission_submitters(payload, template)
      template_submitters_by_role = template.submitters.index_by { |item| item['name'].downcase }
      default_submitter = template.submitters.first

      Array.wrap(payload['submitters']).map.with_index do |attrs, index|
        attrs = attrs.to_h.deep_stringify_keys
        role = attrs['role'].to_s.strip.presence || template.submitters.dig(index, 'name') || default_submitter['name']
        template_submitter = template_submitters_by_role[role.downcase] || default_submitter

        permitted = attrs.slice(
          'send_email', 'send_sms', 'completed_redirect_url', 'uuid', 'name', 'email', 'role',
          'completed', 'phone', 'application_key', 'external_id', 'reply_to', 'go_to_last',
          'require_phone_2fa', 'require_email_2fa', 'order', 'index', 'invite_by',
          'metadata', 'values', 'roles', 'readonly_fields', 'message', 'fields'
        )

        permitted['role'] = template_submitter['name']
        permitted.with_indifferent_access
      end
    end

    def normalize_submission_params(payload, submitters)
      attrs = payload.slice(
        'send_email', 'send_sms', 'bcc_completed', 'completed_redirect_url', 'reply_to',
        'go_to_last', 'require_phone_2fa', 'require_email_2fa', 'expire_at', 'name',
        'variables', 'message'
      )

      attrs['send_email'] = true unless attrs.key?('send_email')
      attrs['send_sms'] = false unless attrs.key?('send_sms')
      attrs['submitters'] = submitters
      attrs.with_indifferent_access
    end

    def truthy?(value)
      value.in?([true, 'true', '1', 1, 'yes', 'on'])
    end
  end

  # Rack middleware that injects an AGPL §13 Corresponding Source offer into
  # rendered HTML responses. The footer link points network-interacting users
  # at the public source of this modification.
  class SourceOfferMiddleware
    SOURCE_URL = 'https://github.com/puran-water/docuseal-customizations'
    MARKER = 'data-puranos-source-offer'
    FOOTER_HTML = (
      %(<div #{MARKER}="1" ) +
      %(style="position:fixed;bottom:8px;right:12px;font:11px/1.4 system-ui,sans-serif;) +
      %(color:#666;background:rgba(255,255,255,0.85);padding:4px 8px;border-radius:6px;) +
      %(z-index:9999;pointer-events:auto;">) +
      %(Modified Docuseal Community — ) +
      %(<a href="#{SOURCE_URL}" rel="noopener noreferrer" target="_blank" ) +
      %(style="color:inherit;text-decoration:underline;">source</a></div>)
    ).freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      return [status, headers, body] unless should_inject?(status, headers, body)

      content = +''
      body.each { |chunk| content << chunk.to_s }
      body.close if body.respond_to?(:close)

      return [status, headers, [content]] if content.include?(MARKER)

      injected = content.sub(%r{</body>}i) { |m| "#{FOOTER_HTML}#{m}" }
      headers = headers.dup
      headers['Content-Length'] = injected.bytesize.to_s if headers['Content-Length']
      [status, headers, [injected]]
    rescue StandardError => e
      PuranWaterDocusealCustomizations.log("source-offer middleware error: #{e.class}: #{e.message}", e)
      raise
    end

    private

    def should_inject?(status, headers, body)
      return false unless status == 200
      ct = headers['Content-Type'] || headers['content-type']
      return false unless ct && ct.to_s.include?('text/html')
      te = headers['Transfer-Encoding'] || headers['transfer-encoding']
      return false if te.to_s == 'chunked'
      return false if body.respond_to?(:to_path)
      true
    end
  end
end

# Defer until after_initialize: config/initializers run during boot before the
# app's models/controllers/lib services are loaded, so the constant probes in
# install! would (and did) fail there. after_initialize runs post-eager-load,
# when every required constant resolves. install! stays guarded, so a future
# DocuSeal upgrade that renames an internal still no-ops cleanly (routes simply
# aren't appended) rather than crashing boot.
# Middleware registers during config phase (before middleware stack freezes);
# install! defers to after_initialize because it probes app constants that
# only resolve post-eager-load.
if defined?(Rails) && Rails.respond_to?(:application) && Rails.application.respond_to?(:config)
  Rails.application.config.middleware.use PuranWaterDocusealCustomizations::SourceOfferMiddleware
  Rails.application.config.after_initialize do
    PuranWaterDocusealCustomizations.install!
  end
else
  PuranWaterDocusealCustomizations.install!
end

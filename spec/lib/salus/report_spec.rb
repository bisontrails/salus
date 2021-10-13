require_relative '../../spec_helper.rb'

describe Salus::Report do
  let(:report) { build_report }
  let(:scan_reports) { (0...3).map { build_scan_report } }

  describe '#to_h and miscellaneous reporting methods' do
    it 'emits the expected reporting data via the #to_h method' do
      name = 'Neon Genesis Evangelion'
      custom_info = { bitcoin_price: 100_000 }
      config = { lemurs: 'contained', raptors: 'loose' }

      report = Salus::Report.new(project_name: name, custom_info: custom_info, config: config)

      # The actual content here doesn't really matter -
      # that functionality is speced out in the ScanReport unit tests
      scan_reports = (1..5).map do |index|
        scan_report = Salus::ScanReport.new("Scanner#{index}")
        scan_report.info(:safe, 'maybe')
        scan_report.error(message: 'something amiss')
        scan_report.dependency(dependency_file: 'libxml2.so.2')
        scan_report.pass
        scan_report
      end

      scan_reports.each { |scan_report| report.add_scan_report(scan_report, required: false) }

      (1..5).map { |index| report.error(message: 'some top-level error', data: index) }

      hsh = report.to_h

      expect(hsh.fetch(:project_name)).to eq(name)
      expect(hsh.fetch(:custom_info)).to eq(custom_info)
      expect(hsh.fetch(:config)).to eq(config)

      hsh.fetch(:errors).each do |error|
        expect(error[:message]).to eq('some top-level error')
        expect((1..5)).to cover(error[:data])
      end

      scans = hsh.fetch(:scans)

      expectation =
        scan_reports
          .map { |scan_report, _required| [scan_report.scanner_name, scan_report.to_h] }
          .to_h

      expect(scans).to eq(expectation)
    end

    it 'should apply filters for to_h' do
      report = Salus::Report.new
      allow(report).to receive(:apply_report_hash_filters).and_wrap_original do |_method, arg|
        arg[:version]
      end
      expect(report).to receive(:apply_report_hash_filters)
      expect(report.to_h).to eq(Salus::VERSION)
    end

    it 'should apply filters for to_sarif' do
      report = Salus::Report.new
      allow(report).to receive(:apply_report_sarif_filters).and_wrap_original do |_method, arg|
        sarif = JSON.parse(arg)
        sarif["$schema"] = "foo"
        sarif.to_json
      end
      expect(report).to receive(:apply_report_sarif_filters)
      sarif = report.to_sarif
      expect(sarif).to eq('{"version":"2.1.0","$schema":"foo","runs":[]}')
    end

    it 'does not include project_name/custom_info/config if not given' do
      report = Salus::Report.new
      hsh = report.to_h
      expect(hsh.key?(:project_name)).to eq(false)
      expect(hsh.key?(:custom_info)).to eq(false)
      expect(hsh.key?(:config)).to eq(false)
    end
  end

  describe '#passed?' do
    it 'returns true if and only if all required scans passed' do
      passed_scan_reports = (0...5).map do
        scan_report = Salus::ScanReport.new('DerpScanner')
        scan_report.pass
        scan_report
      end

      failed_scan_reports = (0...5).map do
        scan_report = Salus::ScanReport.new('HerpScanner')
        scan_report.fail
        scan_report
      end

      # No scans; passed
      report = Salus::Report.new
      expect(report.passed?).to eq(true)

      # All scans required; all passed
      report = Salus::Report.new
      passed_scan_reports.each do |scan_report|
        report.add_scan_report(scan_report, required: true)
      end
      expect(report.passed?).to eq(true)

      # All scans not required; all passed
      report = Salus::Report.new
      passed_scan_reports.each do |scan_report|
        report.add_scan_report(scan_report, required: false)
      end
      expect(report.passed?).to eq(true)

      # All scans required; all failed
      report = Salus::Report.new
      failed_scan_reports.each do |scan_report|
        report.add_scan_report(scan_report, required: true)
      end
      expect(report.passed?).to eq(false)

      # All scans not required; all failed
      report = Salus::Report.new
      failed_scan_reports.each do |scan_report|
        report.add_scan_report(scan_report, required: false)
      end
      expect(report.passed?).to eq(true)

      # All scans required; several passed scans but one failed scan
      report = Salus::Report.new
      report.add_scan_report(failed_scan_reports[0], required: true)
      passed_scan_reports.each do |scan_report|
        report.add_scan_report(scan_report, required: true)
      end
      expect(report.passed?).to eq(false)

      # Mix of required and un-required scans; all failed scans not required
      report = Salus::Report.new
      (passed_scan_reports + failed_scan_reports).each do |scan_report|
        required = scan_report.passed? && rand < 0.5
        report.add_scan_report(scan_report, required: required)
      end
      expect(report.passed?).to eq(true)
    end
  end

  describe '#export_report' do
    def build_report(report_uri)
      report = Salus::Report.new(
        report_uris: [report_uri],
        project_name: 'eva00',
        custom_info: 'test unit'
      )

      3.times do
        scan_report = Salus::ScanReport.new('DerpScanner')
        scan_report.info(:asdf, 'qwerty')
        scan_report.fail
        report.add_scan_report(scan_report, required: true)
      end

      5.times { report.error(message: 'derp') }

      report
    end

    context 'HTTP report URI given' do
      it 'should make a call to send the report for http URI' do
        url = 'https://nerv.tk3/salus-report'
        directive = { 'uri' => url, 'format' => 'json' }
        report = build_report(directive)

        stub_request(:post, url)
          .with(headers: { 'Content-Type' => 'application/json' }, body: report.to_json)
          .to_return(status: 202)

        expect { report.export_report }.not_to raise_error

        assert_requested(
          :post,
          url,
          headers: { 'Content-Type' => 'application/json' },
          body: report.to_json,
          times: 1
        )
      end

      it 'should raise if there is an error with sending the report to a HTTP endpoint' do
        url = 'https://nerv.tk3/salus-report'
        directive = { 'uri' => url, 'format' => 'json' }
        report = build_report(directive)

        stub_request(:post, url)
          .with(headers: { 'Content-Type' => 'application/json' }, body: report.to_json)
          .to_return(status: 404)

        expect { report.export_report }.to raise_error(
          Salus::Report::ExportReportError,
          'Salus report to https://nerv.tk3/salus-report had response status 404.'
        )
      end
    end

    context 'HTTP report URI given with request parameters' do
      it 'should make a call to send the json report for http URI' do
        url = 'https://nerv.tk3/salus-report'
        params = { 'salus_report_param_name' => 'report',
          'additional_params' => { "foo" => "bar", "abc" => "def" } }
        directive = { 'uri' => url, 'format' => 'json',
                      'post' => params }
        report = build_report(directive)

        stub_request(:post, "https://nerv.tk3/salus-report").with(body: "{\n  \"foo\": \"bar\",\n"\
          "  \"abc\": \"def\",\n  \"report\": {\n    \"version\": \"2.13.4\",\n    \"project_nam"\
          "e\": \"eva00\",\n    \"passed\": false,\n    \"scans\": {\n      \"DerpScanner\": {\n "\
          "       \"scanner_name\": \"DerpScanner\",\n        \"passed\": false,\n        \"warn"\
          "\": {\n        },\n        \"info\": {\n          \"asdf\": \"qwerty\"\n        },\n "\
          "       \"errors\": [\n\n        ]\n      }\n    },\n    \"errors\": [\n      {\n      "\
          "  \"message\": \"derp\"\n      },\n      {\n        \"message\": \"derp\"\n      },\n "\
          "     {\n        \"message\": \"derp\"\n      },\n      {\n        \"message\": \"derp"\
          "\"\n      },\n      {\n        \"message\": \"derp\"\n      }\n    ],\n    \"custom_"\
          "info\": \"test unit\"\n  }\n}",
           headers: { 'Accept' => '*/*',
        'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
        'Content-Type' => 'application/json',
        'User-Agent' => 'Faraday v1.3.0',
        'X-Scanner' => 'salus' }).to_return(status: 200, body: "", headers: {})

        expect { report.export_report }.not_to raise_error
      end

      it 'should make a call to send the yaml report for http URI' do
        url = 'https://nerv.tk3/salus-report'
        params = { 'salus_report_param_name' => 'report',
          'additional_params' => { "foo" => "bar", "abc" => "def" } }
        directive = { 'uri' => url, 'format' => 'yaml', 'post' => params }
        report = build_report(directive)

        stub_request(:post, "https://nerv.tk3/salus-report").with(body: "---\nfoo: bar\nabc: def\n"\
          "report:\n  :version: 2.13.4\n  :project_name: eva00\n  :passed: false\n  :scans:\n    "\
          "DerpScanner:\n      :scanner_name: DerpScanner\n      :passed: false\n      :warn: {}\n"\
          "      :info:\n        :asdf: qwerty\n      :errors: []\n  :errors:\n  - :message: derp"\
          "\n  - :message: derp\n  - :message: derp\n  - :message: derp\n  - :message: derp\n  "\
          ":custom_info: test unit\n",
           headers: { 'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Content-Type' => 'text/x-yaml',
            'User-Agent' => 'Faraday v1.3.0',
            'X-Scanner' => 'salus' }).to_return(status: 200, body: "", headers: {})

        expect { report.export_report }.not_to raise_error
      end

      it 'should make a call to send the txt report for http URI' do
        url = 'https://nerv.tk3/salus-report'
        params = { 'salus_report_param_name' => 'report',
          'additional_params' => { "foo" => "bar", "abc" => "def" } }
        directive = { 'uri' => url, 'format' => 'txt', 'post' => params, 'verbose': false }
        report = build_report(directive)
        report.instance_variable_set(:@scan_reports, [])
        config = { 'sources' => { 'valid' => ['word'] } }.deep_symbolize_keys
        report.instance_variable_set(:@config, config)

        stub_request(:post, "https://nerv.tk3/salus-report").with(body: "{\"foo\"=>\"bar\", \"abc"\
          "\"=>\"def\", \"report\"=>\"==== Salus Scan v2.13.4 for eva00\\n\\n==== Salus "\
          "Configuration Files Used:\\n\\n  word\\n\\n\\n==== Salus Errors\\n\\n  [\\n    {\\n    "\
          "  \\\"message\\\": \\\"derp\\\"\\n    },\\n    {\\n      \\\"message\\\": \\\"derp\\"\
          "\"\\n    },\\n    {\\n      \\\"message\\\": \\\"derp\\\"\\n    },\\n    {\\n      "\
          "\\\"message\\\": \\\"derp\\\"\\n    },\\n    {\\n      \\\"message\\\": \\\"derp\\\"\\n"\
          "    }\\n  ]\\n\\n\\nOverall scan status: PASSED\\n\\n┌─────────┬──────────────┬────────"\
          "──┬────────┐\\n│ Scanner │ Running Time │ Required │ Passed │\\n├─────────┼────────────"\
          "──┼──────────┼────────┤\\n\\n└─────────┴──────────────┴──────────┴────────┘\"}",
          headers: { 'Accept' => '*/*',
          'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
          'Content-Type' => 'text/plain',
          'User-Agent' => 'Faraday v1.3.0',
          'X-Scanner' => 'salus' }).to_return(status: 200, body: "", headers: {})
        expect { report.export_report }.not_to raise_error
      end
      it 'should make a call to send the sarif report for http URI' do
        url = 'https://nerv.tk3/salus-report'
        params = { 'salus_report_param_name' => 'report',
          'additional_params' => { "foo" => "bar", "abc" => "def" } }
        options = { 'foo' => 'bar' }
        directive = { 'uri' => url, 'format' => 'sarif', 'post' => params,
                      'verbose': false, 'sarif_options' => options }
        report = build_report(directive)
        report.instance_variable_set(:@scan_reports, [])

        stub_request(:post, "https://nerv.tk3/salus-report").with(
          body: "{\n  \"foo\": \"bar\",\n  \"abc\": \"def\",\n  \"report\": {\n    \"version\": "\
          "\"2.1.0\",\n    \"$schema\": \"https://docs.oasis-open.org/sarif/sarif/v2.1.0/csprd01/"\
          "schemas/sarif-schema-2.1.0\",\n    \"runs\": [\n\n    ]\n  }\n}",
          headers: { 'Accept' => '*/*',
            'Accept-Encoding' => 'gzip;q=1.0,deflate;q=0.6,identity;q=0.3',
            'Content-Type' => 'application/json',
            'User-Agent' => 'Faraday v1.3.0',
            'X-Scanner' => 'salus_sarif' }
        ).to_return(status: 200, body: "", headers: {})

        expect(report).to receive(:to_sarif).with(options).and_call_original.twice
        expect { report.export_report }.not_to raise_error
      end
    end

    context 'local file report URI given' do
      it 'should save to the given directory for a local file uri' do
        path = './spec/fixtures/report/salus_report.json'
        directive = { 'uri' => path, 'format' => 'json' }
        report = build_report(directive)

        # Delete the fixtures file for cleanup - do at start incase last test run failed.
        remove_file(path)

        # Save report
        report.export_report

        # Check save
        expect(File.read(path)).to eq(report.to_json)

        # Delete the fixtures file for cleanup.
        remove_file(path)
      end

      it 'should raise if it tries to write a file report to a non-existent directory' do
        path = './spec/fixtures/non_existent_dir/salus_report.json'
        directive = { 'uri' => path, 'format' => 'json' }
        report = report = build_report(directive)

        report = Salus::Report.new(
          report_uris: [directive],
          project_name: 'eva00',
          custom_info: 'test unit'
        )

        expect { report.export_report }.to raise_error(
          Salus::Report::ExportReportError,
          "Cannot write file #{path} - " \
          "Errno::ENOENT: No such file or directory @ rb_sysopen - "      \
          "./spec/fixtures/non_existent_dir/salus_report.json"
        )
      end
    end

    context 'x-scanner type' do
      it 'should get the correct x-scanner based on format' do
        report = Salus::ReportRequest
        expect(report.x_scanner_type('json')).to eq('salus')
        expect(report.x_scanner_type('yaml')).to eq('salus')
        expect(report.x_scanner_type('sarif_diff')).to eq('salus_sarif_diff')
      end
    end
  end
end

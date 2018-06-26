require 'spec_helper'
require 'puppetserver/ca/cli'

require 'tmpdir'
require 'stringio'
require 'fileutils'
require 'openssl'

RSpec.describe Puppetserver::Ca::Cli do
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def with_files_in(tmpdir, &block)
    bundle_file = File.join(tmpdir, 'bundle.pem')
    key_file = File.join(tmpdir, 'key.pem')
    chain_file = File.join(tmpdir, 'chain.pem')

    not_before = Time.now - 1

    root_key = OpenSSL::PKey::RSA.new(1024)
    root_cert = OpenSSL::X509::Certificate.new
    root_cert.public_key = root_key.public_key
    root_cert.subject = OpenSSL::X509::Name.parse("/CN=foo")
    root_cert.issuer = root_cert.subject
    root_cert.version = 2
    root_cert.serial = rand(2**128)
    root_cert.not_before = not_before
    root_cert.not_after = not_before + 360000
    root_ef = OpenSSL::X509::ExtensionFactory.new
    root_ef.issuer_certificate = root_cert
    root_ef.subject_certificate = root_cert

    [
      ["basicConstraints", "CA:TRUE", true],
      ["keyUsage", "keyCertSign, cRLSign", true],
      ["subjectKeyIdentifier", "hash", false],
      ["authorityKeyIdentifier", "keyid:always", false]
    ].each do |ext|
      extension = root_ef.create_extension(*ext)
      root_cert.add_extension(extension)
    end
    root_cert.sign(root_key, OpenSSL::Digest::SHA256.new)

    leaf_key = OpenSSL::PKey::RSA.new(1024)
    File.open(key_file, 'w') do |f|
      f.puts leaf_key.to_pem
    end

    leaf_cert = OpenSSL::X509::Certificate.new
    leaf_cert.public_key = leaf_key.public_key
    leaf_cert.subject = OpenSSL::X509::Name.parse("/CN=bar")
    leaf_cert.issuer = root_cert.subject
    leaf_cert.version = 2
    leaf_cert.serial = rand(2**128)
    leaf_cert.not_before = not_before
    leaf_cert.not_after = not_before + 360000
    leaf_ef = OpenSSL::X509::ExtensionFactory.new
    leaf_ef.issuer_certificate = root_cert
    leaf_ef.subject_certificate = leaf_cert

    [
      ["basicConstraints", "CA:TRUE", true],
      ["keyUsage", "keyCertSign, cRLSign", true],
      ["subjectKeyIdentifier", "hash", false],
      ["authorityKeyIdentifier", "keyid:always", false]
    ].each do |ext|
      extension = leaf_ef.create_extension(*ext)
      leaf_cert.add_extension(extension)
    end
    leaf_cert.sign(root_key, OpenSSL::Digest::SHA256.new)

    File.open(bundle_file, 'w') do |f|
      f.puts leaf_cert.to_pem
      f.puts root_cert.to_pem
    end

    root_crl = OpenSSL::X509::CRL.new
    root_crl.version = 1
    root_crl.issuer = root_cert.subject
    root_crl.add_extension(
      root_ef.create_extension(["authorityKeyIdentifier", "keyid:always", false]))
    root_crl.add_extension(
      OpenSSL::X509::Extension.new("crlNumber", OpenSSL::ASN1::Integer(0)))
    root_crl.last_update = not_before
    root_crl.next_update = not_before + 360000
    root_crl.sign(root_key, OpenSSL::Digest::SHA256.new)

    leaf_crl = OpenSSL::X509::CRL.new
    leaf_crl.version = 1
    leaf_crl.issuer = leaf_cert.subject
    leaf_crl.add_extension(
      leaf_ef.create_extension(["authorityKeyIdentifier", "keyid:always", false]))
    leaf_crl.add_extension(
      OpenSSL::X509::Extension.new("crlNumber", OpenSSL::ASN1::Integer(0)))
    leaf_crl.last_update = not_before
    leaf_crl.next_update = not_before + 360
    leaf_crl.sign(leaf_key, OpenSSL::Digest::SHA256.new)

    File.open(chain_file, 'w') do |f|
      f.puts leaf_crl.to_pem
      f.puts root_crl.to_pem
    end


    block.call(bundle_file, key_file, chain_file)
  end

  shared_examples 'basic cli args' do |subcommand, usage|
    it 'responds to a --help flag' do
      args = [subcommand, '--help'].compact
      exit_code = Puppetserver::Ca::Cli.run!(args, stdout, stderr)
      expect(stdout.string).to match(usage)
      expect(exit_code).to be 0
    end

    it 'prints the help output & returns 1 if no input is given' do
      args = [subcommand].compact
      exit_code = Puppetserver::Ca::Cli.run!(args, stdout, stderr)
      expect(stderr.string).to match(usage)
      expect(exit_code).to be 1
    end

    it 'prints the version' do
      semverish = /\d+\.\d+\.\d+(-[a-z0-9._-]+)?/
      args = [subcommand, '--version'].compact
      first_code = Puppetserver::Ca::Cli.run!(args, stdout, stderr)
      expect(stdout.string).to match(semverish)
      expect(stderr.string).to be_empty
      expect(first_code).to be 0
    end
  end

  describe 'general options' do
    include_examples 'basic cli args',
      nil,
      /.*Usage: puppetserver ca <command> .*This general help output.*/m
  end

  describe 'the setup subcommand' do
    let(:usage) do
      /.*Usage: puppetserver ca setup.*This setup specific help output.*/m
    end

    include_examples 'basic cli args',
      'setup',
      /.*Usage: puppetserver ca setup.*This setup specific help output.*/m

    it 'does not print the help output if called correctly' do
      Dir.mktmpdir do |tmpdir|
        with_files_in tmpdir do |bundle, key, chain|
          exit_code = Puppetserver::Ca::Cli.run!(['setup',
                                                  '--cert-bundle', bundle,
                                                  '--private-key', key,
                                                  '--crl-chain', chain],
                                                stdout, stderr)
          expect(stderr.string).to be_empty
          expect(exit_code).to be 0
        end
      end
    end

    context 'validation' do
      it 'requires both the --cert-bundle and --private-key options' do
        exit_code = Puppetserver::Ca::Cli.run!(
                      ['setup', '--private-key', 'foo'],
                      stdout,
                      stderr)
        expect(stderr.string).to include('Missing required argument')
        expect(stderr.string).to match(usage)
        expect(exit_code).to be 1

        exit_code = Puppetserver::Ca::Cli.run!(
                      ['setup', '--cert-bundle', 'foo'],
                      stdout,
                      stderr)
        expect(stderr.string).to include('Missing required argument')
        expect(stderr.string).to match(usage)
        expect(exit_code).to be 1
      end

      it 'warns when no CRL is given' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key],
                          stdout,
                          stderr)
            expect(stderr.string).to include('Full CRL chain checking will not be possible')
          end
        end
      end

      it 'requires cert-bundle, private-key, and crl-chain to be readable' do
        # All errors are surfaced from validations
        Dir.mktmpdir do |tmpdir|
          exit_code = Puppetserver::Ca::Cli.run!(
                        ['setup',
                         '--cert-bundle', File.join(tmpdir, 'cert_bundle.pem'),
                         '--private-key', File.join(tmpdir, 'private_key.pem'),
                         '--crl-chain', File.join(tmpdir, 'crl_chain.pem')],
                        stdout, stderr)
          expect(stderr.string).to match(/Could not read .*cert_bundle.pem/)
          expect(stderr.string).to match(/Could not read .*private_key.pem/)
          expect(stderr.string).to match(/Could not read .*crl_chain.pem/)
          expect(exit_code).to be 1
        end
      end

      it 'validates all certs in bundle are parseable' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(bundle, 'a') do |f|
              f.puts '-----BEGIN CERTIFICATE-----'
              f.puts 'garbage'
              f.puts '-----END CERTIFICATE-----'
            end
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not parse .*bundle.pem/)
            expect(stderr.string).to include('garbage')
          end
        end
      end

      it 'validates that there are certs in the bundle' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(bundle, 'w') {|f| f.puts '' }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not detect .*bundle.pem/)
          end
        end
      end

      it 'validates the private key' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(key, 'w') {|f| f.puts '' }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not parse .*key.pem/)
          end
        end
      end

      it 'validates the private key and leaf cert match' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(key, 'w') {|f| f.puts OpenSSL::PKey::RSA.new(1024).to_pem }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to include('Private key and certificate do not match')
          end
        end
      end

      it 'validates all crls in chain are parseable' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(chain, 'a') do |f|
              f.puts '-----BEGIN X509 CRL-----'
              f.puts 'garbage'
              f.puts '-----END X509 CRL-----'
            end
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not parse .*chain.pem/)
            expect(stderr.string).to include('garbage')
          end
        end
      end

      it 'validates that there are crls in the chain, if given chain' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            File.open(chain, 'w') {|f| f.puts '' }
            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to match(/Could not detect .*chain.pem/)
          end
        end
      end

      it 'validates the leaf crl and leaf cert match' do
        Dir.mktmpdir do |tmpdir|
          with_files_in tmpdir do |bundle, key, chain|
            crls = File.read(chain).scan(/----BEGIN X509 CRL----.*?----END X509 CRL----/m)

            not_before = Time.now - 1

            baz_key = OpenSSL::PKey::RSA.new(1024)
            baz_cert = OpenSSL::X509::Certificate.new
            baz_cert.public_key = baz_key.public_key
            baz_cert.subject = OpenSSL::X509::Name.parse("/CN=baz")
            baz_cert.issuer = baz_cert.subject
            baz_cert.version = 2
            baz_cert.serial = rand(2**128)
            baz_cert.not_before = not_before
            baz_cert.not_after = not_before + 360
            baz_ef = OpenSSL::X509::ExtensionFactory.new
            baz_ef.issuer_certificate = baz_cert
            baz_ef.subject_certificate = baz_cert

            [
              ["basicConstraints", "CA:TRUE", true],
              ["keyUsage", "keyCertSign, cRLSign", true],
              ["subjectKeyIdentifier", "hash", false],
              ["authorityKeyIdentifier", "keyid:always", false]
            ].each do |ext|
              extension = baz_ef.create_extension(*ext)
              baz_cert.add_extension(extension)
            end
            baz_cert.sign(baz_key, OpenSSL::Digest::SHA256.new)
            baz_crl = OpenSSL::X509::CRL.new
            baz_crl.version = 1
            baz_crl.issuer = baz_cert.subject
            baz_crl.add_extension(
              baz_ef.create_extension(["authorityKeyIdentifier", "keyid:always", false]))
            baz_crl.add_extension(
              OpenSSL::X509::Extension.new("crlNumber", OpenSSL::ASN1::Integer(0)))
            baz_crl.last_update = not_before
            baz_crl.next_update = not_before + 360
            baz_crl.sign(baz_key, OpenSSL::Digest::SHA256.new)

            File.open(chain, 'w') do |f|
              f.puts baz_crl.to_pem
              f.puts crls[1..-1]
            end

            exit_code = Puppetserver::Ca::Cli.run!(
                          ['setup',
                           '--cert-bundle', bundle,
                           '--private-key', key,
                           '--crl-chain', chain],
                          stdout,
                          stderr)

            expect(stderr.string).to include('Leaf CRL was not issued by leaf certificate')
          end
        end
      end

      it 'validates that leaf cert is valid wrt the provided chain/bundle' do
        Dir.mktmpdir do |tmpdir|
          bundle_file = File.join(tmpdir, 'bundle.pem')
          key_file = File.join(tmpdir, 'key.pem')
          chain_file = File.join(tmpdir, 'chain.pem')

          not_before = Time.now - 1

          root_key = OpenSSL::PKey::RSA.new(1024)
          root_cert = OpenSSL::X509::Certificate.new
          root_cert.public_key = root_key.public_key
          root_cert.subject = OpenSSL::X509::Name.parse("/CN=foo")
          root_cert.issuer = root_cert.subject
          root_cert.version = 2
          root_cert.serial = rand(2**128)
          root_cert.not_before = not_before
          root_cert.not_after = not_before + 360
          root_ef = OpenSSL::X509::ExtensionFactory.new
          root_ef.issuer_certificate = root_cert
          root_ef.subject_certificate = root_cert

          [
            ["basicConstraints", "CA:TRUE", true],
            ["keyUsage", "keyCertSign, cRLSign", true],
            ["subjectKeyIdentifier", "hash", false],
            ["authorityKeyIdentifier", "keyid:always", false]
          ].each do |ext|
            extension = root_ef.create_extension(*ext)
            root_cert.add_extension(extension)
          end
          root_cert.sign(root_key, OpenSSL::Digest::SHA256.new)

          leaf_key = OpenSSL::PKey::RSA.new(1024)
          File.open(key_file, 'w') do |f|
            f.puts leaf_key.to_pem
          end

          leaf_cert = OpenSSL::X509::Certificate.new
          leaf_cert.public_key = leaf_key.public_key
          leaf_cert.subject = OpenSSL::X509::Name.parse("/CN=bar")
          leaf_cert.issuer = root_cert.subject
          leaf_cert.version = 2
          leaf_cert.serial = rand(2**128)
          leaf_cert.not_before = not_before
          leaf_cert.not_after = not_before + 360
          leaf_ef = OpenSSL::X509::ExtensionFactory.new
          leaf_ef.issuer_certificate = root_cert
          leaf_ef.subject_certificate = leaf_cert

          [
            ["basicConstraints", "CA:TRUE", true],
            ["keyUsage", "keyCertSign, cRLSign", true],
            ["subjectKeyIdentifier", "hash", false],
            ["authorityKeyIdentifier", "keyid:always", false]
          ].each do |ext|
            extension = leaf_ef.create_extension(*ext)
            leaf_cert.add_extension(extension)
          end
          leaf_cert.sign(root_key, OpenSSL::Digest::SHA256.new)

          File.open(bundle_file, 'w') do |f|
            f.puts leaf_cert.to_pem
            f.puts root_cert.to_pem
          end

          root_crl = OpenSSL::X509::CRL.new
          root_crl.version = 1
          root_crl.issuer = root_cert.subject
          root_crl.add_extension(
            root_ef.create_extension(["authorityKeyIdentifier",
                                      "keyid:always",
                                      false]))
          root_crl.add_extension(
            OpenSSL::X509::Extension.new("crlNumber",
                                         OpenSSL::ASN1::Integer(1)))
          revoked = OpenSSL::X509::Revoked.new
          revoked.serial = leaf_cert.serial
          revoked.time = Time.now
          revoked.add_extension(
            OpenSSL::X509::Extension.new(
              "CRLReason",
              OpenSSL::ASN1::Enumerated(
                OpenSSL::OCSP::REVOKED_STATUS_KEYCOMPROMISE)))

          root_crl.add_revoked(revoked)
          root_crl.last_update = not_before
          root_crl.next_update = not_before + 360
          root_crl.sign(root_key, OpenSSL::Digest::SHA256.new)

          leaf_crl = OpenSSL::X509::CRL.new
          leaf_crl.version = 1
          leaf_crl.issuer = leaf_cert.subject
          leaf_crl.add_extension(
            leaf_ef.create_extension(["authorityKeyIdentifier",
                                      "keyid:always",
                                      false]))
          leaf_crl.add_extension(
            OpenSSL::X509::Extension.new("crlNumber",
                                         OpenSSL::ASN1::Integer(0)))
          leaf_crl.last_update = not_before
          leaf_crl.next_update = not_before + 360
          leaf_crl.sign(leaf_key, OpenSSL::Digest::SHA256.new)

          File.open(chain_file, 'w') do |f|
            f.puts leaf_crl.to_pem
            f.puts root_crl.to_pem
          end

          exit_code = Puppetserver::Ca::Cli.run!(['setup',
                                                  '--private-key', key_file,
                                                  '--cert-bundle', bundle_file,
                                                  '--crl-chain', chain_file],
                                                  stdout,
                                                  stderr)

          expect(stderr.string).to include('Leaf certificate could not be validated')
        end
      end
    end
  end
end

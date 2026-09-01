# frozen_string_literal: true

module CoreIntelDependencies
  CORE_INTEL_TAP = "shivammathur/core-intel"
  SOURCE_PATH = Pathname(__FILE__).freeze

  def self.extended(formula)
    formula.include FormulaMethods
  end

  def depends_on(dependency)
    super(rewrite_core_dependency(dependency))
  end

  private

  def rewrite_core_dependency(dependency)
    case dependency
    when String
      rewrite_core_dependency_name(dependency)
    when Hash
      dependency.transform_keys do |name|
        name.is_a?(String) ? rewrite_core_dependency_name(name) : name
      end
    else
      dependency
    end
  end

  def rewrite_core_dependency_name(name)
    return name if name.include?("/")

    on_system_conditional(
      macos: on_arch_conditional(
        arm:   name,
        intel: "#{CORE_INTEL_TAP}/#{name}",
      ),
      linux: name,
    )
  end

  module FormulaMethods
    private

    def install_core_intel_dependencies
      lib.mkpath
      (lib/CoreIntelDependencies::SOURCE_PATH.basename).write CoreIntelDependencies::SOURCE_PATH.read
    end

    def core_formula(name)
      dependency = deps.find { |dep| Utils.name_from_full_name(dep.name) == name }
      raise "Dependency #{name} is not declared" unless dependency

      Formula[dependency.name]
    end
  end
end

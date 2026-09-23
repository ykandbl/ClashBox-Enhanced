import localUnitTest from './LocalUnit.test';
import stableCoreUnitTest from './StableCoreUnit.test';
import ruleTemplateUnitTest from './RuleTemplateUnit.test';

export default function testsuite() {
  localUnitTest();
  stableCoreUnitTest();
  ruleTemplateUnitTest();
}

"""L10N-09: переносимый статический RU/EN gate без служб, профилей и Git baseline."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
from typing import Any

CYRILLIC = re.compile('[А-Яа-яЁё]')
# Комментарии не считаем UI-текстом. Этот lexer намеренно ограничен обычными
# Swift literals: raw/multiline/interpolation отмечаются как неподдержанные.
TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|(?P<string>"(?:\\.|[^"\\])*")', re.S)
CALLS = re.compile(r'(?P<receiver>\b\w+)\.(?P<method>text|format|render|runtimeText|runtimeMessage|bilingual)\s*\(')
METHODS = {'runtimeText', 'runtimeMessage', 'bilingual'}


# Адресный review 37 ранее неподдержанных мест. Любая правка caller/producer
# делает annotation stale; без нового review место снова явно unreviewed.
SCOPED_REVIEW = [{'path': 'EcosystemClientAdapters/CodexAdapter.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': 'e079096ff430150b3674298b567ecaa361da5b00ea4e73bb466177ca923c3c5e',
  'callsiteSHA256': '01386bf0b70d1723a577e32806d2ae3797231d1d42cc019155cdfb0dc6fba019',
  'category': 'technical-verbatim',
  'reviewBasis': 'Raw-syntax flag is a false positive on literal TOML # comment delimiters; '
                 'generated managed role/config bytes intentionally stay unchanged, not '
                 'user-facing translation keys.',
  'producerSHA256': {}},
 {'path': 'EcosystemClientAdapters/HarnessPatch.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': 'cd3ecab252bdf2b59faf2c48ac573e09073270b96b606c45bf4398e435dc820c',
  'callsiteSHA256': '01386bf0b70d1723a577e32806d2ae3797231d1d42cc019155cdfb0dc6fba019',
  'category': 'technical-verbatim',
  'reviewBasis': 'Multiline YAML/embedded ESM builds versioned managed profiles; runtime tool '
                 'IDs/filter expressions and persona bytes are intentionally preserved for '
                 'separate managed migration, not interpreted as catalogue keys.',
  'producerSHA256': {}},
 {'path': 'EcosystemLocalIPC/LocalAutomationService.swift',
  'line': 91,
  'column': 23,
  'sourceSHA256': 'f6a623b4ec06d71675d3b7c1fdcac4c7d7ea42a6df4347400a81db91f430a712',
  'callsiteSHA256': '83a1d167e8da7938e449feea3a45ba7191b9b1ee00b4d62cdc39b0dfc2020113',
  'category': 'typed-finite-enum',
  'reviewBasis': 'AgentLocalization.text only accepts AgentText/SharedText. Arguments here are '
                 'finite ternaries automationAttention/automationCompleted and '
                 'agentAres/agentAthena, or automationAttention; no stored event.summary lookup.',
  'producerSHA256': {'EcosystemLocalization/AgentLocalization.swift': 'bf0651496ba621a8c55de4f7b94ad37bfff1e94d50b94f1d578fe883ef6d51cf'}},
 {'path': 'EcosystemLocalIPC/LocalAutomationService.swift',
  'line': 138,
  'column': 28,
  'sourceSHA256': 'f6a623b4ec06d71675d3b7c1fdcac4c7d7ea42a6df4347400a81db91f430a712',
  'callsiteSHA256': '0adce0e069da4f863d31b377cfcbd2a4c5c6cc95f64a7b695ca6f4d87abca1b8',
  'category': 'typed-finite-enum',
  'reviewBasis': 'AgentLocalization.text only accepts AgentText/SharedText. Arguments here are '
                 'finite ternaries automationAttention/automationCompleted and '
                 'agentAres/agentAthena, or automationAttention; no stored event.summary lookup.',
  'producerSHA256': {'EcosystemLocalization/AgentLocalization.swift': 'bf0651496ba621a8c55de4f7b94ad37bfff1e94d50b94f1d578fe883ef6d51cf'}},
 {'path': 'EcosystemLocalIPC/LocalAutomationService.swift',
  'line': 139,
  'column': 27,
  'sourceSHA256': 'f6a623b4ec06d71675d3b7c1fdcac4c7d7ea42a6df4347400a81db91f430a712',
  'callsiteSHA256': '2dbb8b34c1e5ed75d13252fd241a63a76968da10812577d4f47f7db4bc935bc1',
  'category': 'typed-finite-enum',
  'reviewBasis': 'AgentLocalization.text only accepts AgentText/SharedText. Arguments here are '
                 'finite ternaries automationAttention/automationCompleted and '
                 'agentAres/agentAthena, or automationAttention; no stored event.summary lookup.',
  'producerSHA256': {'EcosystemLocalization/AgentLocalization.swift': 'bf0651496ba621a8c55de4f7b94ad37bfff1e94d50b94f1d578fe883ef6d51cf'}},
 {'path': 'EcosystemLocalIPC/LocalContracts.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': '2b0c5f23947a41223023e30fe1e51b676a349995ec67881ab0a9f507c091919e',
  'callsiteSHA256': '54e953840ba5fbce8eb3c17b04f841762edc793c27349e75bb726e17610700e2',
  'category': 'technical-verbatim',
  'reviewBasis': 'Raw literals are cdhash/service validation regular expressions; exact ASCII '
                 'syntax, no translation keys or user text lookup.',
  'producerSHA256': {}},
 {'path': 'EcosystemLocalIPC/MCPInputSchemaValidator.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': 'c3df8c278f18cf901ededa492c5ecf77189574d7046a6e8a294f82dd35c8f4f5',
  'callsiteSHA256': 'a70f586aac8bcdd38fbc9e673e50590298a894949553c4750631471436b3f26f',
  'category': 'technical-verbatim',
  'reviewBasis': 'Raw literal is fixed RFC3339/UTC validation regex; technical protocol syntax '
                 'must remain invariant.',
  'producerSHA256': {}},
 {'path': 'EcosystemLocalIPC/MCPStdioTransport.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': '0cd47e5f91c3721ff78f7334a437f4b879ccecd810ebbfa4665ed24ee295f5dd',
  'callsiteSHA256': '55aac2c2aa641984035e30775100e49413795cb00816ca20cebbecec6f805d78',
  'category': 'technical-verbatim',
  'reviewBasis': 'Raw literal is fixed JSON-RPC request-limit envelope with stable '
                 'MCP_REQUEST_LIMIT code; no user data or translated key.',
  'producerSHA256': {}},
 {'path': 'EcosystemLocalization/LocalizationProbe.swift',
  'line': 18,
  'column': 38,
  'sourceSHA256': '650cc59a061856a477716e1de48850c47a5a77f7c63178161a50567b808d473e',
  'callsiteSHA256': '1fc786ae562f49f0a1c91c9ac037e78e7f574a2c03eaec44192905d90770d26c',
  'category': 'typed-finite-enum',
  'reviewBasis': 'Probe externalPermissions is SharedText; $0 comes directly from '
                 'AgentText.allCases.map. No profile/history/user data enters key.',
  'producerSHA256': {}},
 {'path': 'EcosystemLocalization/LocalizationProbe.swift',
  'line': 20,
  'column': 56,
  'sourceSHA256': '650cc59a061856a477716e1de48850c47a5a77f7c63178161a50567b808d473e',
  'callsiteSHA256': 'fbdce4ad2efe483faa47840ecb460eef2743235108c54d3fabd6e11ba5a4a13a',
  'category': 'typed-finite-enum',
  'reviewBasis': 'Probe externalPermissions is SharedText; $0 comes directly from '
                 'AgentText.allCases.map. No profile/history/user data enters key.',
  'producerSHA256': {}},
 {'path': 'FileOrganizer/Services/MCPHealthCheck.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': 'a6cd6276ee5dcc1b24cdabd042062cb2f83ad787e1f02748c713e51d29a14921',
  'callsiteSHA256': '55aac2c2aa641984035e30775100e49413795cb00816ca20cebbecec6f805d78',
  'category': 'technical-verbatim',
  'reviewBasis': 'Multiline literal is fixed initialize/tools-list JSON-RPC handshake written to '
                 'local pipe; technical version/method IDs, no user data interpolation.',
  'producerSHA256': {}},
 {'path': 'FileOrganizer/Views/AgentSettingsSections.swift',
  'line': 34,
  'column': 49,
  'sourceSHA256': '981fcb0cd92250576b7e16e571a02869c3e903cb2bbef5600ee24087a8a73b54',
  'callsiteSHA256': 'f15a9399add1e1d31daca902edbf4cabc9fcba585cf55f42170b1983c76877c2',
  'category': 'literal-source-key',
  'reviewBasis': 'Conditional format has exactly two builtin keys Disconnect/Connect %@, both in '
                 'Ares catalogue. ExternalAgent.title is only template argument, never key.',
  'producerSHA256': {'FileOrganizerCore/Services/AgentRegistrationService.swift': '3a3733616530718ee59bc3205837f0369ea13b853d7689fcf02af1fb8bc5f663'}},
 {'path': 'FileOrganizer/Views/ContentView.swift',
  'line': 26,
  'column': 34,
  'sourceSHA256': '9989b639633ff487055107cdb958b35964c879ad888e377a30e05339203d074d',
  'callsiteSHA256': 'dc17506189da6835a991c34b0f8913958ed620b3005347b0d6feadd2d6f3b261',
  'category': 'typed-finite-enum',
  'reviewBasis': 'selectedSection is AppSection?, default overview. AppSection.title is exhaustive '
                 'enum switch of builtin labels.',
  'producerSHA256': {'FileOrganizer/Models/AppSection.swift': '924696725a214c4bc754da5bd799af174bbddffcc83db03fffaeddcb6bd2485f'}},
 {'path': 'FileOrganizer/Views/DuplicatesView.swift',
  'line': 85,
  'column': 19,
  'sourceSHA256': '0af53265dd158829f59567eecd69aca4e6b9026ac08f533b5c2a29e3340e823b',
  'callsiteSHA256': '2d890e2e74bd0a2b2a286e55669cbcb493147ca7d030d41e80aac26880732a38',
  'category': 'typed-finite-enum',
  'reviewBasis': 'assessment is FileLocationAssessment.assess; enum returns one of four fixed raw '
                 'labels. File path is input to classifier, never localization key.',
  'producerSHA256': {'FileOrganizerCore/Models/FileLocationAssessment.swift': '76b8b8a6d10ab4e12d39380782c68df509eb7d1a8c12bb0eba00343d38960450'}},
 {'path': 'FileOrganizer/Views/FeaturePlaceholderView.swift',
  'line': 15,
  'column': 13,
  'sourceSHA256': 'b12e4e069c3fd8e19975040a43a70d363533bce21d7cb900e0daabfd0e703eea',
  'callsiteSHA256': '14ee5d254674491bc44efcd2ecbdfb9e51074674c97d89e4caef31a018c44462',
  'category': 'typed-finite-enum',
  'reviewBasis': 'section parameter has type AppSection, title exhaustive builtin switch; no user '
                 'provided label.',
  'producerSHA256': {'FileOrganizer/Models/AppSection.swift': '924696725a214c4bc754da5bd799af174bbddffcc83db03fffaeddcb6bd2485f'}},
 {'path': 'FileOrganizer/Views/FilesView.swift',
  'line': 53,
  'column': 57,
  'sourceSHA256': '0eb397ca4c9de8e20e37478e68889ff5186c13fbdb0daeb98266f863cae07d53',
  'callsiteSHA256': '40a5d88ef753cb99933a0af3058442bd4d9ff3838befc9d91ab91e7d0150882b',
  'category': 'typed-finite-enum',
  'reviewBasis': '$0 comes directly from FileCollection.allCases; fixed enum raw labels, not '
                 'FileRecord values.',
  'producerSHA256': {'FileOrganizer/ViewModels/FilesViewModel.swift': '9add1df6f7e5f4c5ef297d684bf67b91260433af49fe320f2c342fbd6529b47e'}},
 {'path': 'FileOrganizer/Views/RuleHistoryView.swift',
  'line': 21,
  'column': 57,
  'sourceSHA256': '6df5c4c1654d29298d8b4e8978eadcfa59f4fc5e406413ac23bd70d93a59cc42',
  'callsiteSHA256': '6536ea6fe940bda38586611e1a08c79cc9ce73ff39038d2fbb462c214104a4e6',
  'category': 'typed-finite-enum',
  'reviewBasis': 'result.kind is RuleActionKind; title exhaustive builtin switch. relativePath and '
                 'result.message are separately shown verbatim.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 45,
  'column': 53,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': '4a43de7f66ef2b736cb8f3ce3601bd8e2a7a135f7c8f495977b1d90a9bd83724',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 47,
  'column': 49,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': 'f2c8612cf743e82e86431529437a25d145a9e5117cff6f8993e863f2e631b6ba',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 120,
  'column': 121,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': 'bfb88866bb6d33eaf4faf6c4db32c2bfd3976938e768d1ee9dfc6d8f85629804',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 131,
  'column': 136,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': 'bfb88866bb6d33eaf4faf6c4db32c2bfd3976938e768d1ee9dfc6d8f85629804',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 155,
  'column': 138,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': 'bfb88866bb6d33eaf4faf6c4db32c2bfd3976938e768d1ee9dfc6d8f85629804',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 185,
  'column': 138,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': 'bfb88866bb6d33eaf4faf6c4db32c2bfd3976938e768d1ee9dfc6d8f85629804',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 226,
  'column': 20,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': 'f9fdaf442506ae9dede0089c5afe33f238386c53381f668eb4fa2c0caace5f93',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/RulesView.swift',
  'line': 228,
  'column': 28,
  'sourceSHA256': 'd43f4800127620439a4514da273daf26d6219d7a29b7371f9ce6143ffd9105da',
  'callsiteSHA256': '4d864d68c043a86fb655b910ff44f94914971ff99bba5a002b2b953bab7b8c80',
  'category': 'typed-finite-enum',
  'reviewBasis': 'RuleEvent/RuleActionKind/RuleSchedule/RuleNameMatch titles are exhaustive '
                 'builtin enum labels. dateCondition title has only three literal callers Created '
                 'after/Modified after/First seen after. Rule names/destination names/action '
                 'values remain direct Text/Binding values, not keys.',
  'producerSHA256': {'FileOrganizerCore/Models/AutomationRule.swift': 'e1cf3d2da65829c26916ee2a9d52df60a904bba3279bfe5476c771492c0058e0'}},
 {'path': 'FileOrganizer/Views/SettingsOverviewView.swift',
  'line': 26,
  'column': 55,
  'sourceSHA256': '84be4309faa08f2bb69001ce1647c82e41b32d7ecc4020f4fc450a23f46faf16',
  'callsiteSHA256': '86559e3c4d0dbfcf0cf480135cf6ddd378648d678c16047bc7dbc9cb90ce801e',
  'category': 'typed-finite-enum',
  'reviewBasis': '$0 comes from AppTheme.allCases; title finite exhaustive builtin enum switch, '
                 'raw storage value unchanged.',
  'producerSHA256': {'FileOrganizer/Models/AppTheme.swift': 'd38e318e34296d9112fda9d2e5ae16d185ebc875eab45223296996ecad04e960'}},
 {'path': 'FileOrganizer/Views/SidebarView.swift',
  'line': 18,
  'column': 58,
  'sourceSHA256': 'a7e85487f53a370f4783e376a1e6cfc915fed24c2010add947c97c5986c1af33',
  'callsiteSHA256': '00bf5cb93f3408e2d52213c61a4d79c036df2ec3e4a2939bedb4bbe09032c9a5',
  'category': 'typed-finite-enum',
  'reviewBasis': '$0 comes from AppSection.allCases; builtin title mapping, stable raw IDs kept.',
  'producerSHA256': {'FileOrganizer/Models/AppSection.swift': '924696725a214c4bc754da5bd799af174bbddffcc83db03fffaeddcb6bd2485f'}},
 {'path': 'FileOrganizerCore/Persistence/DatabaseMigration.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': 'ac560b67ef78fc7d808bee74beb508d9bf130660c1f1fb4730d19816e2276746',
  'callsiteSHA256': '55aac2c2aa641984035e30775100e49413795cb00816ca20cebbecec6f805d78',
  'category': 'technical-verbatim',
  'reviewBasis': 'Multiline literals are static SQL DDL migrations; SQL identifiers/data schema '
                 'must not be translated.',
  'producerSHA256': {}},
 {'path': 'FileOrganizerCore/Persistence/SQLiteFileRepository.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': '89a6144041b7aa852cc6191ab2645310ae696a8086755aa77f89d3f11c59febb',
  'callsiteSHA256': '03c55daa06c7c08400f647b9ef6c695503e275c2b6dc2431b8496971f055aabb',
  'category': 'technical-verbatim',
  'reviewBasis': 'Multiline literals are parameterized SQL queries/DDL; stored user names/paths '
                 'remain SQL values, never localization keys.',
  'producerSHA256': {}},
 {'path': 'FileOrganizerCore/Persistence/SQLiteMigrator.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': '65094f3cd6c3d0a7bea998f020c9b3be08e5fdd55d61f0434cdf50ae4835bba4',
  'callsiteSHA256': '03c55daa06c7c08400f647b9ef6c695503e275c2b6dc2431b8496971f055aabb',
  'category': 'technical-verbatim',
  'reviewBasis': 'Multiline literal is schema_migrations DDL; technical schema syntax, not '
                 'localized output.',
  'producerSHA256': {}},
 {'path': 'FileOrganizerMCP/FileOrganizerMCPEntry.swift',
  'line': 130,
  'column': 178,
  'sourceSHA256': 'f6afff760a4119d14c0a2298279b254ca03b40a4aef372d69973c46de74caa84',
  'callsiteSHA256': 'd8796521a1efa08861f18169c310b0ea755b541c17426bc6f749b432140ed591',
  'category': 'literal-source-key',
  'reviewBasis': 'private definition helper has only fixed literal descriptions from '
                 'definitions/localDefinitions; all current callers read, descriptions bilingual, '
                 'user args never forwarded into description key.',
  'producerSHA256': {}},
 {'path': 'MacAssistant/Views/Diagnostics/DiagnosticsView.swift',
  'line': 39,
  'column': 30,
  'sourceSHA256': '33b091f7c9a2bc64d73dd42768eecb47d9e87cf6267733d036258204ffd06500',
  'callsiteSHA256': '5369fba3a6c469f0b1066bf7e66ad87c8dcb2794e65d3324848152c42c33898b',
  'category': 'literal-source-key',
  'reviewBasis': 'Finite report.status ternary selects two builtin literals; report findings text '
                 'is rendered separately through code-aware presentation or verbatim fallback.',
  'producerSHA256': {'MacAssistantCore/Models/DiagnosticReport.swift': '292d40bedf2e1d0e311568445257beb19c8fd22e5b68022b27737bcb88b3804f'}},
 {'path': 'MacAssistant/Views/SidebarView.swift',
  'line': 17,
  'column': 58,
  'sourceSHA256': 'd3fc221e7f7372fae593c5baa2f809c0ef013d9c26a7a54e14ce2066465ac7a1',
  'callsiteSHA256': '00bf5cb93f3408e2d52213c61a4d79c036df2ec3e4a2939bedb4bbe09032c9a5',
  'category': 'typed-finite-enum',
  'reviewBasis': '$0 comes from AppSection.allCases; title exhaustive builtin enum switch.',
  'producerSHA256': {'MacAssistant/Models/AppSection.swift': 'd94a419918107adc4cad8f0c5d8129472326b0e556dfe9f78004598040de7e64'}},
 {'path': 'HarnessAgentTool/main.swift',
  'line': 1,
  'column': 1,
  'sourceSHA256': '208535f14c7e21d5d89fe426a96226a36cad79c2405bc98d41213262850f69cd',
  'callsiteSHA256': '54e953840ba5fbce8eb3c17b04f841762edc793c27349e75bb726e17610700e2',
  'category': 'technical-verbatim',
  'reviewBasis': 'Raw literal validates explicit profile identifier against fixed ASCII regex '
                 'before adapter construction; never a localization key.',
  'producerSHA256': {}},
 {'path': 'MacAssistantCore/Models/DiagnosticReport.swift',
  'line': 103,
  'column': 20,
  'sourceSHA256': '292d40bedf2e1d0e311568445257beb19c8fd22e5b68022b27737bcb88b3804f',
  'callsiteSHA256': '4eec62a7ddbe6deff0fc22acfc0e22e424a43cdd869de8ccc36aa19696357820',
  'category': 'typed-finite-code',
  'reviewBasis': 'recognizedPresentationCode checks version1, known DiagnosticPresentationCode '
                 'enum and severity. Only seven finite codes form prefix athena.finding.<code>, '
                 'three literal suffixes. Unknown/legacy codes return self verbatim. All21 runtime '
                 'keys verified.',
  'producerSHA256': {}},
 {'path': 'MacAssistantCore/Models/DiagnosticReport.swift',
  'line': 104,
  'column': 26,
  'sourceSHA256': '292d40bedf2e1d0e311568445257beb19c8fd22e5b68022b27737bcb88b3804f',
  'callsiteSHA256': 'f783e72424bcec5970d53f0b33706db643bd9d452681714a5fd29d4d534a210a',
  'category': 'typed-finite-code',
  'reviewBasis': 'recognizedPresentationCode checks version1, known DiagnosticPresentationCode '
                 'enum and severity. Only seven finite codes form prefix athena.finding.<code>, '
                 'three literal suffixes. Unknown/legacy codes return self verbatim. All21 runtime '
                 'keys verified.',
  'producerSHA256': {}},
 {'path': 'MacAssistantCore/Models/DiagnosticReport.swift',
  'line': 105,
  'column': 29,
  'sourceSHA256': '292d40bedf2e1d0e311568445257beb19c8fd22e5b68022b27737bcb88b3804f',
  'callsiteSHA256': '44f9f4968dc9cec8c65ea5745cc7e3490dd6fd9c4d38437ee90351177566e114',
  'category': 'typed-finite-code',
  'reviewBasis': 'recognizedPresentationCode checks version1, known DiagnosticPresentationCode '
                 'enum and severity. Only seven finite codes form prefix athena.finding.<code>, '
                 'three literal suffixes. Unknown/legacy codes return self verbatim. All21 runtime '
                 'keys verified.',
  'producerSHA256': {}},
 {'path': 'MacAssistant/Views/Processor/ProcessorChart.swift',
 'line': 76,
 'column': 30,
 'sourceSHA256': 'e880799e006db770e9cb80c54083dedd85956953dc48a8159e160931e22a9837',
 'callsiteSHA256': 'ff928dfa02bfa38082349a1f6fa94b2a72d5bc23a7277534babe6d4dbf286a5d',
 'category': 'typed-finite-enum',
 'reviewBasis': 'series comes only from literal arrays ProcessorSeries.total/user/system or core '
                'in ForEach; ProcessorSeries.title is an exhaustive finite enum switch. CPU names '
                'and graph values are verbatim or numeric, never lookup keys.',
 'producerSHA256': {'MacAssistant/Views/Processor/ProcessorViewModel.swift': 'a1c1a3b01bbd576fa165dace303792d9161adf61985d8310cfe32e8c734c468b'}},
 {'path': 'MacAssistant/Views/Processor/ProcessorView.swift',
 'line': 125,
 'column': 70,
 'sourceSHA256': '2bbceb7b917184e76c72dd48ff0c479e5d710266d5b78c69299fe4349308c0ce',
 'callsiteSHA256': 'adfaf41ce2e51ec11454bfb89ffbf0196195cd5b6590a58df494368840ae849e',
 'category': 'typed-finite-enum',
 'reviewBasis': 'value comes only from ProcessorHistoryWindow.allCases (60/300/900); title is an '
                'exhaustive finite enum switch. External processor name is direct Text; core '
                'numbers/time are template arguments, never lookup keys.',
 'producerSHA256': {'MacAssistant/Views/Processor/ProcessorViewModel.swift': 'a1c1a3b01bbd576fa165dace303792d9161adf61985d8310cfe32e8c734c468b'}}]

def require(condition: bool, message: str) -> None:
    """Gate не зависит от python -O: проверку нельзя убрать отключением assert."""
    if not condition:
        raise ValueError(message)


def read_table(path: Path) -> dict[str, str]:
    """plistlib также читает XML .strings, используемые в исходных ресурсах."""
    value = plistlib.loads(path.read_bytes())
    require(isinstance(value, dict) and bool(value), 'Empty/malformed table: ' + str(path))
    require(all(isinstance(k, str) and isinstance(v, str) and v.strip()
                for k, v in value.items()), 'Non-string/empty translation: ' + str(path))
    return value


def placeholders(value: str) -> list[str]:
    """Сохраняем тип и позиционный индекс, но не порядок аргументов перевода."""
    tokens = re.findall(r'%(?:\d+\$)?(?:@|[A-Za-z]+)', value.replace('%%', ''))
    require(all(re.fullmatch(r'%(?:\d+\$)?(?:@|ld|lld|d|lu|llu|f)', token) for token in tokens),
            'Unsupported placeholder specifier')
    return sorted(tokens)


def check_catalogue(base: Path, table: str, count: int | None) -> tuple[dict[str, str], dict[str, Any]]:
    """Размер Runtime расширяемый; фиксированные GUI-каталоги имеют точный размер."""
    ru, en = [read_table(base / (language + '.lproj') / (table + '.strings'))
              for language in ('ru', 'en')]
    require(set(ru) == set(en), 'RU/EN key mismatch: ' + table)
    require(len(ru) == count if count is not None else len(ru) >= 184,
            'Unexpected catalogue count: ' + table)
    for key in ru:
        require(not CYRILLIC.search(en[key]) or (table, key, en[key]) == ('Localizable', 'language.title', 'Language / Язык'),
                'Cyrillic English translation: ' + table + '/' + key)
        require(placeholders(ru[key]) == placeholders(en[key]),
                'Placeholder mismatch: ' + table + '/' + key)
        require('Localization resource unavailable.' not in en[key], 'Fallback in catalogue: ' + key)
    digest = hashlib.sha256(json.dumps([ru, en], sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return ru, {'table': table, 'keysPerLanguage': len(ru), 'keyParity': True,
                'nonemptyValues': True, 'placeholderParity': True, 'sha256': digest}


def check_plurals(base: Path) -> dict[str, Any]:
    """Проверяем таблицы и требуемые целочисленные ветки RU/EN, без Locale mutation.

    Это независимый расчёт категорий для указанных целых, не утверждение о
    выполнении Foundation. Нативный eventCount проверяется Swift tests/probes.
    """
    results: dict[str, list[str]] = {}
    for language in ('ru', 'en'):
        value = plistlib.loads((base / (language + '.lproj') / 'Localizable.stringsdict').read_bytes())
        require(set(value) == {'events.count'}, 'Unexpected plural keys')
        item = value['events.count']
        require(item['NSStringLocalizedFormatKey'] == '%#@events@', 'Invalid plural format')
        forms = item['events']
        require(forms['NSStringFormatSpecTypeKey'] == 'NSStringPluralRuleType', 'Invalid plural rule')
        require(forms['NSStringFormatValueTypeKey'] == 'ld', 'Invalid plural integer type')
        expected = {'one': '%ld событие', 'few': '%ld события', 'many': '%ld событий', 'other': '%ld события'} if language == 'ru' else {'one': '%ld event', 'other': '%ld events'}
        # RU other может использовать форму «событий»: требуем валидный template,
        # а точные образцы ниже затрагивают только целые категории one/few/many.
        for key in expected:
            require(key in forms and placeholders(forms[key]) == ['%ld'], 'Missing plural branch: ' + key)
        rendered: list[str] = []
        for number in (0, 1, 2, 5, 11, 21, 101):
            category = ('one' if number % 10 == 1 and number % 100 != 11 else
                        'few' if 2 <= number % 10 <= 4 and not 12 <= number % 100 <= 14 else 'many') if language == 'ru' else ('one' if number == 1 else 'other')
            text = forms[category].replace('%ld', str(number))
            require(text == expected[category].replace('%ld', str(number)), 'Incorrect plural sample: ' + text)
            rendered.append(text)
        results[language] = rendered
    return {'samples': results, 'nativeFoundationExecution': False}


def annotation_fresh(annotation: dict[str, Any], source_hash: str, callsite_hash: str,
                     producer_hashes: dict[str, str]) -> bool:
    """Проверенный caller без прежнего producer больше не считается проверенным."""
    return (annotation['sourceSHA256'] == source_hash
            and annotation['callsiteSHA256'] == callsite_hash
            and all(producer_hashes.get(path) == digest
                    for path, digest in annotation['producerSHA256'].items()))


def source_audit(directory: Path, keys: set[str], runtime_keys: set[str], label: str,
                 gui: bool, producer_hashes: dict[str, str] | None = None) -> dict[str, Any]:
    """Проверяем literal keys; семантику динамических выражений не выдумываем.

    Параметры внешних строк допускаются в templates/verbatim. Без Swift AST
    нельзя доказать происхождение каждого аргумента: такие места перечисляем.
    """
    unsupported: list[dict[str, Any]] = []
    static_count = 0
    files = sorted(directory.rglob('*.swift'))
    require(bool(files), 'Missing Swift source directory: ' + str(directory))
    for path in files:
        source = path.read_text()
        # Маскировка комментариев сохраняет offsets/номера строк. Строки остаются.
        matches = list(TOKENS.finditer(source))
        masked = list(source)
        for match in matches:
            if match.group('string') is None:
                masked[match.start():match.end()] = ['\n' if c == '\n' else ' ' for c in match.group()]
        clean = ''.join(masked)
        relative = label + '/' + path.relative_to(directory).as_posix()
        def note(offset: int, reason: str) -> None:
            line_start = source.rfind('\n', 0, offset) + 1
            line_end = source.find('\n', offset)
            snippet = source[offset:line_end if line_end >= 0 else len(source)].strip()
            # Allowlist ограничен проверенными API boundaries, а не именами
            # произвольных полей. Full data-flow ни одна категория не доказывает.
            category, basis = 'unreviewed', 'Requires source-aware semantic review'
            if label == 'EcosystemUI' and re.match(r'(?:l10n|localization)\.text\(', snippet):
                category = 'typed-finite-enum'
                basis = 'AgentLocalization.text accepts only SharedText/AgentText; catalogue parity and Swift typed tests are separate gates'
            elif re.match(r'\w+\.(?:render|runtimeMessage)\(', snippet):
                category = 'deferred-message'
                basis = 'Deferred message API preserves explicit verbatim/template cases; argument provenance still requires Swift tests/review'
            elif label == 'MacAssistant' and re.match(r'l10n\.text\((?:SettingsBlock\.|appearance\.title|MonitorPresentation\.statusTitle|MonitorViewModel\.metricTitle|Self\.metricTitle)', snippet):
                category = 'typed-finite-enum'
                basis = 'Reviewed Athena SettingsBlock/AppAppearance/Monitor enum-to-caption boundary; stored/raw values unchanged'
            elif 'raw/multiline' in reason:
                category = 'technical-unparsed'
                basis = 'Lexer cannot prove raw/multiline syntax; this entry remains unreviewed'
            matching = next((item for item in SCOPED_REVIEW if item['path'] == relative
                             and item['line'] == source.count('\n', 0, offset) + 1
                             and item['column'] == offset - line_start + 1), None)
            scoped_reviewed = False
            if matching:
                fresh = annotation_fresh(matching, hashlib.sha256(source.encode()).hexdigest(),
                                         hashlib.sha256(snippet.encode()).hexdigest(),
                                         producer_hashes or {})
                if fresh:
                    category, basis = matching['category'], matching['reviewBasis']
                    scoped_reviewed = True
                else:
                    category, basis = 'unreviewed-stale', 'Reviewed caller or producer hash changed; repeat scoped review'
            unsupported.append({'path': relative, 'line': source.count('\n', 0, offset) + 1,
                                'column': offset - line_start + 1, 'reason': reason,
                                'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
                                'callsiteSHA256': hashlib.sha256(snippet.encode()).hexdigest(),
                                'snippet': snippet, 'category': category, 'reviewBasis': basis,
                                'reviewedBoundaryShape': scoped_reviewed or category in {'typed-finite-enum', 'deferred-message'}})
        for call in CALLS.finditer(clean):
            receiver, method = call['receiver'], call['method']
            is_runtime = method in METHODS
            # Имена всех прочих .text/.format API не относятся к локализатору.
            if not is_runtime and not (receiver == 'l10n' or receiver.endswith('L10n') or receiver == 'localization'):
                continue
            tail = clean[call.end():].lstrip()
            literal = TOKENS.match(tail)
            if literal is None or literal.group('string') is None:
                note(call.start(), 'dynamic/typed key or deferred message; semantic review required')
                continue
            remainder = tail[literal.end():].lstrip()
            if remainder.startswith('+') or tail.startswith('"""'):
                note(call.start(), 'composed/raw/multiline key; semantic review required')
                continue
            try:
                key = json.loads(literal.group('string'))
            except json.JSONDecodeError:
                note(call.start(), 'Swift interpolation/escape requires Swift-aware review')
                continue
            target = runtime_keys if is_runtime else keys
            require(key in target, 'Unknown localization key: ' + relative + ': ' + key)
            static_count += 1
        if gui:
            for match in matches:
                literal = match.group('string')
                if literal is None or not CYRILLIC.search(literal):
                    continue
                try:
                    key = json.loads(literal)
                except json.JSONDecodeError:
                    note(match.start(), 'GUI interpolated/raw literal needs explicit review')
                    continue
                require(key in keys or key in runtime_keys,
                        'Uncatalogued Cyrillic GUI literal: ' + relative + ': ' + key)
        if '"""' in clean or re.search(r'#+"', clean):
            note(0, 'raw/multiline Swift syntax not fully parsed by this static gate')
    return {'sourceFiles': len(files), 'literalKeysChecked': static_count,
            'unsupportedCases': unsupported, 'semanticDataFlowProven': False,
            'boundaryPolicy': 'External/user/history/error text must remain verbatim or template arguments; dynamic expressions require code review and Swift tests.'}


def run(kit: Path, ares: Path | None, athena: Path | None) -> dict[str, Any]:
    """Пути явные: работает в workspace, standalone CI и vendored publication."""
    base = kit / 'Sources/EcosystemLocalization/Resources'
    report: dict[str, Any] = {'stage': 'L10N-09', 'catalogues': [], 'sourceAudits': [],
                             'servicesStarted': False, 'profilesAccessed': False,
                             'nativeUIOrEnergyClaims': False}
    tables: dict[str, dict[str, str]] = {}
    for table, count in [('Localizable', 16), ('Shared', 208), ('Runtime', None)]:
        tables[table], result = check_catalogue(base, table, count)
        report['catalogues'].append(result)
    report['plurals'] = check_plurals(base)
    runtime_keys = set(tables['Runtime'])
    producer_hashes: dict[str, str] = {}
    roots = [kit / 'Sources'] + [repo / 'Sources' for repo in (ares, athena) if repo is not None]
    for source_root in roots:
        for path in source_root.rglob('*.swift'):
            producer_hashes[path.relative_to(source_root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    # Финитный diagnostic prefix проверен не только по regex имени поля.
    if athena is not None:
        for code in ('storageWarning', 'storageCritical', 'cpuWarning', 'cpuCritical',
                     'memoryWarning', 'memoryCritical', 'noCriticalSigns'):
            for field in ('title', 'explanation', 'recommendation'):
                require('athena.finding.' + code + '.' + field in runtime_keys,
                        'Missing finite diagnostic presentation key')

    report['sourceAudits'].append(source_audit(kit / 'Sources/EcosystemUI', set(), runtime_keys, 'EcosystemUI', False, producer_hashes))
    for child in sorted((kit / 'Sources').iterdir()):
        if child.is_dir() and child.name != 'EcosystemUI' and any(child.rglob('*.swift')):
            report['sourceAudits'].append(source_audit(child, set(), runtime_keys, child.name, False, producer_hashes))
    for repo, product, table, count in [(ares, 'FileOrganizer', 'Ares', 296),
                                       (athena, 'MacAssistant', 'Athena', 297)]:
        if repo is None:
            continue
        own, result = check_catalogue(repo / 'Sources' / product / 'Resources', table, count)
        report['catalogues'].append(result)
        report['sourceAudits'].append(source_audit(repo / 'Sources' / product, set(own), runtime_keys, product, True, producer_hashes))
        for child in sorted((repo / 'Sources').iterdir()):
            if child.is_dir() and child.name != product:
                report['sourceAudits'].append(source_audit(child, set(own), runtime_keys, child.name, False, producer_hashes))
    inventory = [item for audit in report['sourceAudits'] for item in audit['unsupportedCases']]
    counts: dict[str, int] = {}
    for item in inventory:
        counts[item['category']] = counts.get(item['category'], 0) + 1
    report['boundaryInventory'] = inventory
    report['semanticBoundaryReview'] = {
        'groupCounts': counts, 'semanticDataFlowComplete': False,
        'unreviewedCases': sum(not item['reviewedBoundaryShape'] for item in inventory),
        'status': 'declared-boundaries-reviewed' if all(item['reviewedBoundaryShape'] for item in inventory) else 'requires-semantic-review',
        'declaredBoundaryReviewComplete': all(item['reviewedBoundaryShape'] for item in inventory),
        'staticGateScope': 'Resource/literal-key gate passed; this is not a claim that all dynamic/user/history text is semantically verified.',
        'sourceHashFreshness': 'Current snapshot hashed; supply --boundary-baseline for freshness against an externally reviewed report',
    }
    report['scope'] = {'ares': ares is not None, 'athena': athena is not None,
                       'sharedKit': True, 'historicalCoreUnchangedClaim': False}
    return report



def verify_boundary_freshness(baseline: dict[str, Any], report: dict[str, Any]) -> None:
    """Новый/удалённый или изменённый approved callsite требует нового review."""
    def reviewed(value: dict[str, Any]) -> dict[tuple[str, int, int], dict[str, Any]]:
        return {(item['path'], item['line'], item['column']): item
                for item in value['boundaryInventory'] if item['reviewedBoundaryShape']}
    before, current = reviewed(baseline), reviewed(report)
    require(set(before) == set(current), 'Reviewed boundary callsite inventory changed')
    for identity, old in before.items():
        new = current[identity]
        require(new['sourceSHA256'] == old['sourceSHA256']
                and new['callsiteSHA256'] == old['callsiteSHA256'],
                'Stale reviewed boundary: ' + identity[0])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--ares-dir', type=Path)
    parser.add_argument('--athena-dir', type=Path)
    parser.add_argument('--kit-dir', type=Path)
    parser.add_argument('--require-reviewed-boundaries', action='store_true',
                        help='Fail when a declared dynamic/raw boundary lacks a fresh scoped review')
    parser.add_argument('--boundary-baseline', type=Path, help='Previously reviewed report; reject stale reviewed callsites/source hashes')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    ares = args.ares_dir or (args.workspace / 'FileOrganizer' if args.workspace else None)
    athena = args.athena_dir or (args.workspace / 'MacAssistant' if args.workspace else None)
    kit = args.kit_dir or (athena / 'Packages/EcosystemKit' if athena else None)
    require(kit is not None and (ares is not None or athena is not None), 'Provide workspace or explicit repository/Kit paths')
    report = run(kit, ares, athena)
    if args.require_reviewed_boundaries:
        require(report['semanticBoundaryReview']['declaredBoundaryReviewComplete'],
                'Unreviewed/stale declared boundary; inspect inventory and repeat source-aware review')
    if args.boundary_baseline:
        verify_boundary_freshness(json.loads(args.boundary_baseline.read_text()), report)
        report['semanticBoundaryReview']['sourceHashFreshness'] = 'Reviewed baseline source/callsite hashes match current snapshot'
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'staticResourceAndKeyGatePassed': True, 'semanticBoundaryComplete': report['semanticBoundaryReview']['declaredBoundaryReviewComplete'], 'catalogues': len(report['catalogues']),
                      'literalKeysChecked': sum(item['literalKeysChecked'] for item in report['sourceAudits']),
                      'unsupportedSourceCases': sum(len(item['unsupportedCases']) for item in report['sourceAudits'])}))


if __name__ == '__main__':
    main()

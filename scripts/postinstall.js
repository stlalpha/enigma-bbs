#!/usr/bin/env node

/**
 * Post-install bootstrap script for the self-contained installer.
 * Generates a minimal config.hjson and supporting menu files if they are absent.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const hjson = require('hjson');
const minimist = require('minimist');
const sanitize = require('sanitize-filename');

const args = minimist(process.argv.slice(2), {
    string: ['install-dir', 'board-name'],
    default: {
        'board-name': 'New ENiGMA½ BBS',
    },
});

const installDir = path.resolve(args['install-dir'] || path.join(__dirname, '..'));
const boardName = String(args['board-name']).trim() || 'New ENiGMA½ BBS';
const configDir = path.join(installDir, 'config');
const configFile = path.join(configDir, 'config.hjson');
const menuDir = path.join(configDir, 'menus');

const hjsonOptions = {
    emitRootBraces: true,
    bracesSameLine: true,
    space: 4,
    keepWsc: true,
    quotes: 'min',
    eol: '\n',
};

function ensureDir(dirPath) {
    fs.mkdirSync(dirPath, { recursive: true });
}

function copyMenuTemplates(boardKey) {
    ensureDir(menuDir);

    const templatesDir = path.join(installDir, 'misc', 'menu_templates');
    const includeTemplates = [
        'message_base.in.hjson',
        'private_mail.in.hjson',
        'login.in.hjson',
        'new_user.in.hjson',
        'doors.in.hjson',
        'file_base.in.hjson',
        'activitypub.in.hjson',
    ];

    const includes = [];
    includeTemplates.forEach(template => {
        const targetName = `${boardKey}-${template.replace('.in', '')}`;
        const sourcePath = path.join(templatesDir, template);
        const targetPath = path.join(menuDir, targetName);

        if (!fs.existsSync(targetPath) && fs.existsSync(sourcePath)) {
            fs.copyFileSync(sourcePath, targetPath);
        }

        includes.push(targetName);
    });

    const mainTemplatePath = path.join(templatesDir, 'main.in.hjson');
    const mainTemplate = fs.readFileSync(mainTemplatePath, 'utf8');
    const rendered = mainTemplate.replace(/%INCLUDE_FILES%/g, includes.join('\n\t\t'));
    const menuFileName = `${boardKey}-main.hjson`;
    fs.writeFileSync(path.join(menuDir, menuFileName), rendered, 'utf8');

    return path.join(menuDir, menuFileName);
}

function createConfig() {
    if (fs.existsSync(configFile)) {
        console.log('Config already exists, skipping bootstrap.');
        return;
    }

    ensureDir(configDir);

    const defaultConfig = require(path.join(installDir, 'core', 'config_default'))();

    const boardKey = sanitize(boardName)
        .replace(/[^a-z0-9_-]/gi, '_')
        .replace(/_+/g, '_')
        .toLowerCase();

    const menuFile = copyMenuTemplates(boardKey);

    defaultConfig.general.boardName = boardName;
    defaultConfig.general.prettyBoardName = boardName;
    defaultConfig.general.menuFile = menuFile;

    defaultConfig.loginServers.telnet.enabled = false; // encourage secure defaults

    const ensurePaths = [
        defaultConfig.paths.logs,
        defaultConfig.paths.db,
        defaultConfig.paths.modsDb,
        defaultConfig.paths.dropFiles,
        path.join(configDir, 'security'),
    ].filter(Boolean);

    ensurePaths.forEach(ensureDir);

    const rendered = hjson.stringify(defaultConfig, hjsonOptions);
    fs.writeFileSync(configFile, rendered, 'utf8');
    console.log(`Created ${path.relative(installDir, configFile)}`);
}

try {
    createConfig();
} catch (err) {
    console.error('Bootstrap failed:', err.message);
    process.exitCode = 1;
}

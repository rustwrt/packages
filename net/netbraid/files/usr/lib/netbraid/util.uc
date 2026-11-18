'use strict';

import { isnan } from 'math';

export function keys(value) {
	let result = [];
	if (type(value) != 'object')
		return result;
	for (let key in value)
		push(result, key);
	return result;
};

export function isFiniteNumber(value) {
	return (type(value) == 'int' || type(value) == 'double') && !isnan(value) && value - value == 0;
};

export function isInteger(value, minimum, maximum) {
	if (!isFiniteNumber(value) || value !== int(value))
		return false;
	if (minimum !== null && value < minimum)
		return false;
	if (maximum !== null && value > maximum)
		return false;
	return true;
};

export function requireTable(value, label) {
	if (type(value) != 'object')
		die(sprintf('%s must be an object', label));
	return value;
};

export function requireArray(value, label) {
	if (type(value) != 'array')
		die(sprintf('%s must be an array', label));
	return value;
};

export function requireString(value, label) {
	if (type(value) != 'string' || value === '')
		die(sprintf('%s must be a nonempty string', label));
	return value;
};

export function requireInteger(value, minimum, maximum, label) {
	if (!isInteger(value, minimum, maximum))
		die(sprintf('%s must be an integer between %s and %s', label, minimum, maximum));
	return value;
};

export function requireBoolean(value, label) {
	if (value !== true && value !== false)
		die(sprintf('%s must be a boolean', label));
	return value;
};

export function identifier(value, maxLength) {
	maxLength ??= 32;
	return type(value) == 'string' && length(value) >= 1 && length(value) <= maxLength
		&& match(value, /^[A-Za-z_][A-Za-z0-9_.-]*$/) != null;
};

export function toSnakeCase(name) {
	if (type(name) != 'string')
		return name;
	return lc(replace(replace(name, /([A-Z])([A-Z][a-z])/g, '$1_$2'), /([a-z0-9])([A-Z])/g, '$1_$2'));
};

export function snakeCaseKeys(input) {
	if (type(input) != 'object' && type(input) != 'array')
		return input;

	if (type(input) == 'array') {
		let output = [];
		for (let value in input)
			push(output, snakeCaseKeys(value));
		return output;
	}

	let output = {};
	for (let key in input)
		output[toSnakeCase(key)] = snakeCaseKeys(input[key]);
	return output;
};

export function deepCopy(input) {
	if (type(input) != 'object' && type(input) != 'array')
		return input;

	if (type(input) == 'array') {
		let output = [];
		for (let value in input)
			push(output, deepCopy(value));
		return output;
	}

	let output = {};
	for (let key in input)
		output[key] = deepCopy(input[key]);
	return output;
};

export function deepEqual(left, right) {
	if (type(left) != type(right))
		return false;
	if (type(left) != 'object' && type(left) != 'array')
		return left === right;

	if (type(left) == 'array') {
		if (length(left) != length(right))
			return false;
		for (let index = 0; index < length(left); index++)
			if (!deepEqual(left[index], right[index]))
				return false;
		return true;
	}
	let leftKeys = keys(left), rightKeys = keys(right);
	if (length(leftKeys) != length(rightKeys))
		return false;
	for (let key in leftKeys) {
		if (!exists(right, key) || !deepEqual(left[key], right[key]))
			return false;
	}
	return true;
};

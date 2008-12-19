/* valaccodemethodcallmodule.vala
 *
 * Copyright (C) 2006-2008  Jürg Billeter, Raffaele Sandrini
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.

 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.

 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 * 	Jürg Billeter <j@bitron.ch>
 *	Raffaele Sandrini <raffaele@sandrini.ch>
 */

using GLib;
using Gee;

public class Vala.CCodeMethodCallModule : CCodeAssignmentModule {
	public CCodeMethodCallModule (CCodeGenerator codegen, CCodeModule? next) {
		base (codegen, next);
	}

	public override void visit_method_call (MethodCall expr) {
		expr.accept_children (codegen);

		// the bare function call
		var ccall = new CCodeFunctionCall ((CCodeExpression) expr.call.ccodenode);

		CCodeFunctionCall async_call = null;

		Method m = null;
		Gee.List<FormalParameter> params;
		
		var ma = expr.call as MemberAccess;
		
		var itype = expr.call.value_type;
		params = itype.get_parameters ();
		
		if (itype is MethodType) {
			assert (ma != null);
			m = ((MethodType) itype).method_symbol;
		} else if (itype is SignalType) {
			var sig_type = (SignalType) itype;
			if (ma != null && ma.inner is BaseAccess && sig_type.signal_symbol.is_virtual) {
				m = sig_type.signal_symbol.get_method_handler ();
			} else {
				ccall = (CCodeFunctionCall) expr.call.ccodenode;
			}
		} else if (itype is ObjectType) {
			// constructor
			var cl = (Class) ((ObjectType) itype).type_symbol;
			m = cl.default_construction_method;
			ccall = new CCodeFunctionCall (new CCodeIdentifier (m.get_real_cname ()));
		}

		HashMap<int,CCodeExpression> in_arg_map, out_arg_map;

		if (m != null && m.coroutine
		    && ((current_method != null && current_method.coroutine)
		        || (ma.member_name == "begin" && ma.inner.symbol_reference == ma.symbol_reference))) {
			// async call

			in_arg_map = new HashMap<int,CCodeExpression> (direct_hash, direct_equal);
			out_arg_map = new HashMap<int,CCodeExpression> (direct_hash, direct_equal);

			async_call = new CCodeFunctionCall (new CCodeIdentifier (m.get_cname () + "_async"));

			if (ma.member_name == "begin" && ma.inner.symbol_reference == ma.symbol_reference) {
				// no finish call
				ccall = async_call;
			} else {
				ccall = new CCodeFunctionCall (new CCodeIdentifier (m.get_cname () + "_finish"));

				// pass GAsyncResult stored in closure to finish function
				out_arg_map.set (get_param_pos (0.1), new CCodeMemberAccess.pointer (new CCodeIdentifier ("data"), "res"));
			}
		} else {
			in_arg_map = new HashMap<int,CCodeExpression> (direct_hash, direct_equal);
			out_arg_map = in_arg_map;
		}

		if (m is CreationMethod) {
			ccall.add_argument (new CCodeIdentifier ("object_type"));
		}

		// the complete call expression, might include casts, comma expressions, and/or assignments
		CCodeExpression ccall_expr = ccall;

		if (m is ArrayResizeMethod) {
			var array_type = (ArrayType) ma.inner.value_type;
			in_arg_map.set (get_param_pos (0), new CCodeIdentifier (array_type.element_type.get_cname ()));
		} else if (m is ArrayMoveMethod) {
			requires_array_move = true;
		}

		CCodeExpression instance = null;
		if (m != null && m.binding == MemberBinding.INSTANCE && !(m is CreationMethod)) {
			instance = (CCodeExpression) ma.inner.ccodenode;

			if (ma.member_name == "begin" && ma.inner.symbol_reference == ma.symbol_reference) {
				var inner_ma = (MemberAccess) ma.inner;
				instance = (CCodeExpression) inner_ma.inner.ccodenode;
			}

			var st = m.parent_symbol as Struct;
			if (st != null && !st.is_simple_type ()) {
				// we need to pass struct instance by reference
				var unary = instance as CCodeUnaryExpression;
				if (unary != null && unary.operator == CCodeUnaryOperator.POINTER_INDIRECTION) {
					// *expr => expr
					instance = unary.inner;
				} else if (instance is CCodeIdentifier || instance is CCodeMemberAccess) {
					instance = new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, instance);
				} else {
					// if instance is e.g. a function call, we can't take the address of the expression
					// (tmp = expr, &tmp)
					var ccomma = new CCodeCommaExpression ();

					var temp_var = get_temp_variable (ma.inner.target_type);
					temp_vars.insert (0, temp_var);
					ccomma.append_expression (new CCodeAssignment (get_variable_cexpression (temp_var.name), instance));
					ccomma.append_expression (new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, get_variable_cexpression (temp_var.name)));

					instance = ccomma;
				}
			}

			in_arg_map.set (get_param_pos (m.cinstance_parameter_position), instance);
			out_arg_map.set (get_param_pos (m.cinstance_parameter_position), instance);
		} else if (m != null && m.binding == MemberBinding.CLASS) {
			var cl = (Class) m.parent_symbol;
			var cast = new CCodeFunctionCall (new CCodeIdentifier (cl.get_upper_case_cname (null) + "_CLASS"));
			
			CCodeExpression klass;
			if (ma.inner == null) {
				if (in_static_or_class_ctor) {
					// Accessing the method from a static or class constructor
					klass = new CCodeIdentifier ("klass");
				} else {
					// Accessing the method from within an instance method
					var k = new CCodeFunctionCall (new CCodeIdentifier ("G_OBJECT_GET_CLASS"));
					k.add_argument (new CCodeIdentifier ("self"));
					klass = k;
				}
			} else {
				// Accessing the method of an instance
				var k = new CCodeFunctionCall (new CCodeIdentifier ("G_OBJECT_GET_CLASS"));
				k.add_argument ((CCodeExpression) ma.inner.ccodenode);
				klass = k;
			}

			cast.add_argument (klass);
			in_arg_map.set (get_param_pos (m.cinstance_parameter_position), cast);
			out_arg_map.set (get_param_pos (m.cinstance_parameter_position), cast);
		}

		if (m is ArrayMoveMethod) {
			var array_type = (ArrayType) ma.inner.value_type;
			var csizeof = new CCodeFunctionCall (new CCodeIdentifier ("sizeof"));
			csizeof.add_argument (new CCodeIdentifier (array_type.element_type.get_cname ()));
			in_arg_map.set (get_param_pos (0.1), csizeof);
		} else if (m is DynamicMethod) {
			m.clear_parameters ();
			int param_nr = 1;
			foreach (Expression arg in expr.get_argument_list ()) {
				var unary = arg as UnaryExpression;
				if (unary != null && unary.operator == UnaryOperator.OUT) {
					// out argument
					var param = new FormalParameter ("param%d".printf (param_nr), unary.inner.value_type);
					param.direction = ParameterDirection.OUT;
					m.add_parameter (param);
				} else if (unary != null && unary.operator == UnaryOperator.REF) {
					// ref argument
					var param = new FormalParameter ("param%d".printf (param_nr), unary.inner.value_type);
					param.direction = ParameterDirection.REF;
					m.add_parameter (param);
				} else {
					// in argument
					m.add_parameter (new FormalParameter ("param%d".printf (param_nr), arg.value_type));
				}
				param_nr++;
			}
			foreach (FormalParameter param in m.get_parameters ()) {
				param.accept (codegen);
			}
			head.generate_dynamic_method_wrapper ((DynamicMethod) m);
		} else if (m is CreationMethod) {
			ccall_expr = new CCodeAssignment (new CCodeIdentifier ("self"), new CCodeCastExpression (ccall, current_class.get_cname () + "*"));
		}

		bool ellipsis = false;
		
		int i = 1;
		int arg_pos;
		Iterator<FormalParameter> params_it = params.iterator ();
		foreach (Expression arg in expr.get_argument_list ()) {
			CCodeExpression cexpr = (CCodeExpression) arg.ccodenode;

			var carg_map = in_arg_map;

			if (params_it.next ()) {
				var param = params_it.get ();
				ellipsis = param.params_array || param.ellipsis;
				if (!ellipsis) {
					// if the vala argument expands to multiple C arguments,
					// we have to make sure that the C arguments don't depend
					// on each other as there is no guaranteed argument
					// evaluation order
					// http://bugzilla.gnome.org/show_bug.cgi?id=519597
					bool multiple_cargs = false;

					if (param.direction == ParameterDirection.OUT) {
						carg_map = out_arg_map;
					}

					if (!param.no_array_length && param.parameter_type is ArrayType) {
						var array_type = (ArrayType) param.parameter_type;
						for (int dim = 1; dim <= array_type.rank; dim++) {
							carg_map.set (get_param_pos (param.carray_length_parameter_position + 0.01 * dim), head.get_array_length_cexpression (arg, dim));
						}
						multiple_cargs = true;
					} else if (param.parameter_type is DelegateType) {
						var deleg_type = (DelegateType) param.parameter_type;
						var d = deleg_type.delegate_symbol;
						if (d.has_target) {
							var delegate_target = get_delegate_target_cexpression (arg);
							if (deleg_type.value_owned) {
								CCodeExpression delegate_target_destroy_notify;
								var delegate_method = arg.symbol_reference as Method;
								var arg_ma = arg as MemberAccess;
								if (delegate_method != null && delegate_method.binding == MemberBinding.INSTANCE
								    && arg_ma.inner != null && arg_ma.inner.value_type.data_type != null
								    && arg_ma.inner.value_type.data_type.is_reference_counting ()) {
									var ref_call = new CCodeFunctionCall (get_dup_func_expression (arg_ma.inner.value_type, arg.source_reference));
									ref_call.add_argument (delegate_target);
									delegate_target = ref_call;
									delegate_target_destroy_notify = get_destroy_func_expression (arg_ma.inner.value_type);
								} else {
									delegate_target_destroy_notify = new CCodeConstant ("NULL");
								}
								carg_map.set (get_param_pos (param.cdelegate_target_parameter_position + 0.01), delegate_target_destroy_notify);
 							}
							carg_map.set (get_param_pos (param.cdelegate_target_parameter_position), delegate_target);
							multiple_cargs = true;
						}
					} else if (param.parameter_type is MethodType) {
						carg_map.set (get_param_pos (param.cdelegate_target_parameter_position), get_delegate_target_cexpression (arg));
						multiple_cargs = true;
					}

					cexpr = handle_struct_argument (param, arg, cexpr);

					if (multiple_cargs && arg is MethodCall) {
						// if vala argument is invocation expression
						// the auxiliary C argument(s) will depend on the main C argument

						// (tmp = arg1, call (tmp, arg2, arg3,...))

						var ccomma = new CCodeCommaExpression ();

						var temp_decl = get_temp_variable (arg.value_type);
						temp_vars.insert (0, temp_decl);
						ccomma.append_expression (new CCodeAssignment (get_variable_cexpression (temp_decl.name), cexpr));

						cexpr = new CCodeIdentifier (temp_decl.name);

						ccomma.append_expression (ccall_expr);

						ccall_expr = ccomma;
					}

					// unref old value for non-null non-weak ref/out arguments
					// disabled for arrays for now as that requires special handling
					// (ret_tmp = call (&tmp), var1 = (assign_tmp = dup (tmp), free (var1), assign_tmp), ret_tmp)
					if (param.direction != ParameterDirection.IN && requires_destroy (arg.value_type)
					    && (param.direction == ParameterDirection.OUT || !param.parameter_type.value_owned)
					    && !(param.parameter_type is ArrayType)) {
						var unary = (UnaryExpression) arg;

						var ccomma = new CCodeCommaExpression ();

						var temp_var = get_temp_variable (param.parameter_type, param.parameter_type.value_owned);
						temp_vars.insert (0, temp_var);
						cexpr = new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, get_variable_cexpression (temp_var.name));

						if (param.direction == ParameterDirection.REF) {
							var crefcomma = new CCodeCommaExpression ();
							crefcomma.append_expression (new CCodeAssignment (get_variable_cexpression (temp_var.name), (CCodeExpression) unary.inner.ccodenode));
							crefcomma.append_expression (cexpr);
							cexpr = crefcomma;
						}

						// call function
						LocalVariable ret_temp_var = null;
						if (itype.get_return_type () is VoidType) {
							ccomma.append_expression (ccall_expr);
						} else {
							ret_temp_var = get_temp_variable (itype.get_return_type ());
							temp_vars.insert (0, ret_temp_var);
							ccomma.append_expression (new CCodeAssignment (get_variable_cexpression (ret_temp_var.name), ccall_expr));
						}

						var cassign_comma = new CCodeCommaExpression ();

						var assign_temp_var = get_temp_variable (unary.inner.value_type, unary.inner.value_type.value_owned);
						temp_vars.insert (0, assign_temp_var);

						cassign_comma.append_expression (new CCodeAssignment (get_variable_cexpression (assign_temp_var.name), transform_expression (get_variable_cexpression (temp_var.name), param.parameter_type, unary.inner.value_type, arg)));

						// unref old value
						cassign_comma.append_expression (get_unref_expression ((CCodeExpression) unary.inner.ccodenode, arg.value_type, arg));

						cassign_comma.append_expression (get_variable_cexpression (assign_temp_var.name));

						// assign new value
						ccomma.append_expression (new CCodeAssignment ((CCodeExpression) unary.inner.ccodenode, cassign_comma));

						// return value
						if (!(itype.get_return_type () is VoidType)) {
							ccomma.append_expression (get_variable_cexpression (ret_temp_var.name));
						}

						ccall_expr = ccomma;
					}

					if (param.ctype != null) {
						cexpr = new CCodeCastExpression (cexpr, param.ctype);
					}
				}
				arg_pos = get_param_pos (param.cparameter_position, ellipsis);
			} else {
				// default argument position
				arg_pos = get_param_pos (i, ellipsis);
			}

			carg_map.set (arg_pos, cexpr);

			i++;
		}
		if (params_it.next ()) {
			var param = params_it.get ();

			/* if there are more parameters than arguments,
			 * the additional parameter is an ellipsis parameter
			 * otherwise there is a bug in the semantic analyzer
			 */
			assert (param.params_array || param.ellipsis);
			ellipsis = true;
		}

		/* add length argument for methods returning arrays */
		if (m != null && m.return_type is ArrayType) {
			var array_type = (ArrayType) m.return_type;
			for (int dim = 1; dim <= array_type.rank; dim++) {
				if (!m.no_array_length) {
					var temp_var = get_temp_variable (int_type);
					var temp_ref = get_variable_cexpression (temp_var.name);

					temp_vars.insert (0, temp_var);

					out_arg_map.set (get_param_pos (m.carray_length_parameter_position + 0.01 * dim), new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, temp_ref));

					expr.append_array_size (temp_ref);
				} else {
					expr.append_array_size (new CCodeConstant ("-1"));
				}
			}
		} else if (m != null && m.return_type is DelegateType) {
			var deleg_type = (DelegateType) m.return_type;
			var d = deleg_type.delegate_symbol;
			if (d.has_target) {
				var temp_var = get_temp_variable (new PointerType (new VoidType ()));
				var temp_ref = get_variable_cexpression (temp_var.name);

				temp_vars.insert (0, temp_var);

				out_arg_map.set (get_param_pos (m.cdelegate_target_parameter_position), new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, temp_ref));

				expr.delegate_target = temp_ref;
			}
		}

		if (m != null && m.coroutine) {
			if ((current_method != null && current_method.coroutine)
			    || (ma.member_name == "begin" && ma.inner.symbol_reference == ma.symbol_reference)) {
				// asynchronous call
				if (ma.member_name == "begin" && ma.inner.symbol_reference == ma.symbol_reference) {
					in_arg_map.set (get_param_pos (-1), new CCodeConstant ("NULL"));
					in_arg_map.set (get_param_pos (-0.9), new CCodeConstant ("NULL"));
				} else {
					in_arg_map.set (get_param_pos (-1), new CCodeIdentifier (current_method.get_cname () + "_ready"));
					in_arg_map.set (get_param_pos (-0.9), new CCodeIdentifier ("data"));
				}
			}
		}

		if (m is CreationMethod && m.get_error_types ().size > 0) {
			out_arg_map.set (get_param_pos (-1), new CCodeIdentifier ("error"));
		} else if (expr.tree_can_fail) {
			// method can fail
			current_method_inner_error = true;
			// add &inner_error before the ellipsis arguments
			out_arg_map.set (get_param_pos (-1), new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, get_variable_cexpression ("inner_error")));
		}

		if (ellipsis) {
			/* ensure variable argument list ends with NULL
			 * except when using printf-style arguments */
			if (!m.printf_format && m.sentinel != "") {
				in_arg_map.set (get_param_pos (-1, true), new CCodeConstant (m.sentinel));
			}
		} else if (itype is DelegateType) {
			var deleg_type = (DelegateType) itype;
			var d = deleg_type.delegate_symbol;
			if (d.has_target) {
				in_arg_map.set (get_param_pos (d.cinstance_parameter_position), get_delegate_target_cexpression (expr.call));
				out_arg_map.set (get_param_pos (d.cinstance_parameter_position), get_delegate_target_cexpression (expr.call));
			}
		}

		// pass address for the return value of non-void signals without emitter functions
		if (itype is SignalType && !(itype.get_return_type () is VoidType)) {
			var sig = ((SignalType) itype).signal_symbol;

			if (ma != null && ma.inner is BaseAccess && sig.is_virtual) {
				// normal return value for base access
			} else if (!sig.has_emitter) {
				var temp_var = get_temp_variable (itype.get_return_type ());
				var temp_ref = get_variable_cexpression (temp_var.name);

				temp_vars.insert (0, temp_var);

				out_arg_map.set (get_param_pos (-1, true), new CCodeUnaryExpression (CCodeUnaryOperator.ADDRESS_OF, temp_ref));
			
				var ccomma = new CCodeCommaExpression ();
				ccomma.append_expression ((CCodeExpression) ccall_expr);
				ccomma.append_expression ((CCodeExpression) temp_ref);

				ccall_expr = ccomma;
			}
		}

		// append C arguments in the right order
		
		int last_pos;
		int min_pos;

		if (async_call != ccall) {
			// don't append out arguments for .begin() calls
			last_pos = -1;
			while (true) {
				min_pos = -1;
				foreach (int pos in out_arg_map.get_keys ()) {
					if (pos > last_pos && (min_pos == -1 || pos < min_pos)) {
						min_pos = pos;
					}
				}
				if (min_pos == -1) {
					break;
				}
				ccall.add_argument (out_arg_map.get (min_pos));
				last_pos = min_pos;
			}
		}

		if (async_call != null) {
			last_pos = -1;
			while (true) {
				min_pos = -1;
				foreach (int pos in in_arg_map.get_keys ()) {
					if (pos > last_pos && (min_pos == -1 || pos < min_pos)) {
						min_pos = pos;
					}
				}
				if (min_pos == -1) {
					break;
				}
				async_call.add_argument (in_arg_map.get (min_pos));
				last_pos = min_pos;
			}
		}

		if (m != null && m.binding == MemberBinding.INSTANCE && m.returns_modified_pointer) {
			expr.ccodenode = new CCodeAssignment (instance, ccall_expr);
		} else {
			expr.ccodenode = ccall_expr;
		}

		if (m != null && m.coroutine && current_method != null && current_method.coroutine) {
			if (ma.member_name != "begin" || ma.inner.symbol_reference != ma.symbol_reference) {
				if (pre_statement_fragment == null) {
					pre_statement_fragment = new CCodeFragment ();
				}
				pre_statement_fragment.append (new CCodeExpressionStatement (async_call));

				int state = next_coroutine_state++;
				pre_statement_fragment.append (new CCodeExpressionStatement (new CCodeAssignment (new CCodeMemberAccess.pointer (new CCodeIdentifier ("data"), "state"), new CCodeConstant (state.to_string ()))));
				pre_statement_fragment.append (new CCodeReturnStatement (new CCodeConstant ("FALSE")));
				pre_statement_fragment.append (new CCodeCaseStatement (new CCodeConstant (state.to_string ())));
			}
		}

		if (m is ArrayResizeMethod) {
			// FIXME: size expression must not be evaluated twice at runtime (potential side effects)
			Iterator<Expression> arg_it = expr.get_argument_list ().iterator ();
			arg_it.next ();
			var new_size = (CCodeExpression) arg_it.get ().ccodenode;

			var temp_decl = get_temp_variable (int_type);
			var temp_ref = get_variable_cexpression (temp_decl.name);

			temp_vars.insert (0, temp_decl);

			/* memset needs string.h */
			string_h_needed = true;

			var clen = head.get_array_length_cexpression (ma.inner, 1);
			var celems = (CCodeExpression) ma.inner.ccodenode;
			var array_type = (ArrayType) ma.inner.value_type;
			var csizeof = new CCodeIdentifier ("sizeof (%s)".printf (array_type.element_type.get_cname ()));
			var cdelta = new CCodeBinaryExpression (CCodeBinaryOperator.MINUS, temp_ref, clen);
			var ccheck = new CCodeBinaryExpression (CCodeBinaryOperator.GREATER_THAN, temp_ref, clen);

			var czero = new CCodeFunctionCall (new CCodeIdentifier ("memset"));
			czero.add_argument (new CCodeBinaryExpression (CCodeBinaryOperator.PLUS, celems, clen));
			czero.add_argument (new CCodeConstant ("0"));
			czero.add_argument (new CCodeBinaryExpression (CCodeBinaryOperator.MUL, csizeof, cdelta));

			var ccomma = new CCodeCommaExpression ();
			ccomma.append_expression (new CCodeAssignment (temp_ref, new_size));
			ccomma.append_expression ((CCodeExpression) expr.ccodenode);
			ccomma.append_expression (new CCodeConditionalExpression (ccheck, czero, new CCodeConstant ("NULL")));
			ccomma.append_expression (new CCodeAssignment (head.get_array_length_cexpression (ma.inner, 1), temp_ref));

			expr.ccodenode = ccomma;
		}
	}
}

